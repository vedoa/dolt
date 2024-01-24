// Copyright 2024 Dolthub, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package stats

import (
	"errors"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/dolthub/go-mysql-server/sql"
	"github.com/dolthub/go-mysql-server/sql/stats"

	"github.com/dolthub/dolt/go/libraries/doltcore/doltdb/durable"
	"github.com/dolthub/dolt/go/libraries/doltcore/schema"
	"github.com/dolthub/dolt/go/libraries/doltcore/sqle/dsess"
	"github.com/dolthub/dolt/go/libraries/doltcore/sqle/dtables"
	"github.com/dolthub/dolt/go/store/hash"
	"github.com/dolthub/dolt/go/store/prolly"
	"github.com/dolthub/dolt/go/store/prolly/tree"
	"github.com/dolthub/dolt/go/store/val"
)

func loadStats(ctx *sql.Context, dbName string, m prolly.Map) (*dbStats, error) {
	dbStat := &dbStats{db: dbName, active: make(map[hash.Hash]int), stats: make(map[sql.StatQualifier]*DoltStats)}

	iter, err := dtables.NewStatsIter(ctx, m)
	if err != nil {
		return nil, err
	}
	currentStat := &DoltStats{}
	var lowerBound sql.Row
	for {
		row, err := iter.Next(ctx)
		if errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return nil, err
		}

		position := row[schema.StatsPositionTag].(int)

		// deserialize K, V
		dbName := row[schema.StatsDbTag].(string)
		tableName := row[schema.StatsTableTag].(string)
		indexName := row[schema.StatsIndexTag].(string)
		_ = row[schema.StatsVersionTag]
		commit := hash.Parse(row[schema.StatsCommitHashTag].(string))
		rowCount := row[schema.StatsRowCountTag].(uint64)
		distinctCount := row[schema.StatsDistinctCountTag].(uint64)
		nullCount := row[schema.StatsNullCountTag].(uint64)
		columns := strings.Split(row[schema.StatsColumnsTag].(string), ",")
		typesStr := row[schema.StatsTypesTag].(string)
		boundRowStr := row[schema.StatsUpperBoundTag].(string)
		upperBoundCnt := row[schema.StatsUpperBoundCntTag].(uint64)
		createdAt := row[schema.StatsCreatedAtTag].(time.Time)

		typs := strings.Split(typesStr, ",")
		for i, t := range typs {
			typs[i] = strings.TrimSpace(t)
		}

		numMcvs := schema.StatsMcvCountsTag - schema.StatsMcv1Tag

		mcvCountsStr := strings.Split(row[schema.StatsMcvCountsTag].(string), ",")
		mcvCnts := make([]uint64, numMcvs)
		for i, v := range mcvCountsStr {
			val, err := strconv.Atoi(v)
			if err != nil {
				return nil, err
			}
			mcvCnts[i] = uint64(val)
		}

		mcvs := make([]sql.Row, numMcvs)
		for i, v := range row[schema.StatsMcv1Tag:schema.StatsMcvCountsTag] {
			if v != nil {
				row, err := iter.ParseRow(v.(string))
				if err != nil {
					return nil, err
				}
				mcvs[i] = row
			}
		}

		for i, v := range mcvCnts {
			if v == 0 {
				mcvs = mcvs[:i]
				mcvCnts = mcvCnts[:i]
				break
			}
		}

		boundRow, err := iter.ParseRow(boundRowStr)
		if err != nil {
			return nil, err
		}

		qual := sql.NewStatQualifier(dbName, tableName, indexName)
		if currentStat.Qual.String() != qual.String() {
			if currentStat.Qual.String() != "" {
				currentStat.LowerBound, err = loadLowerBound(ctx, currentStat.Qual)
				if err != nil {
					return nil, err
				}
				dbStat.stats[currentStat.Qual] = currentStat
			}
			currentStat = &DoltStats{Qual: qual, Columns: columns, LowerBound: lowerBound}
		}

		if currentStat.Histogram == nil {
			currentStat.Types, err = stats.ParseTypeStrings(typs)
			if err != nil {
				return nil, err
			}
			currentStat.Qual = qual
		}

		bucket := DoltBucket{
			Chunk:         commit,
			RowCount:      uint64(rowCount),
			DistinctCount: uint64(distinctCount),
			NullCount:     uint64(nullCount),
			CreatedAt:     createdAt,
			Mcvs:          mcvs,
			McvCount:      mcvCnts,
			BoundCount:    upperBoundCnt,
			UpperBound:    boundRow,
		}

		dbStat.active[commit] = position
		currentStat.Histogram = append(currentStat.Histogram, bucket)
		currentStat.RowCount += uint64(rowCount)
		currentStat.DistinctCount += uint64(distinctCount)
		currentStat.NullCount += uint64(rowCount)
		if currentStat.CreatedAt.Before(createdAt) {
			currentStat.CreatedAt = createdAt
		}
	}
	dbStat.stats[currentStat.Qual] = currentStat
	return dbStat, nil
}

func loadLowerBound(ctx *sql.Context, qual sql.StatQualifier) (sql.Row, error) {
	dSess := dsess.DSessFromSess(ctx.Session)
	roots, ok := dSess.GetRoots(ctx, qual.Database)
	if !ok {
		return nil, nil
	}

	table, ok, err := roots.Head.GetTable(ctx, qual.Table())
	if !ok {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	idx, err := table.GetIndexRowData(ctx, qual.Index())
	if err != nil {
		return nil, err
	}

	prollyMap := durable.ProllyMapFromIndex(idx)
	keyBuilder := val.NewTupleBuilder(prollyMap.KeyDesc())
	buffPool := prollyMap.NodeStore().Pool()

	firstIter, err := prollyMap.IterOrdinalRange(ctx, 0, 1)
	if err != nil {
		return nil, err
	}
	keyBytes, _, err := firstIter.Next(ctx)
	if err != nil {
		return nil, err
	}
	for i := range keyBuilder.Desc.Types {
		keyBuilder.PutRaw(i, keyBytes.GetField(i))
	}

	firstKey := keyBuilder.Build(buffPool)
	var firstRow sql.Row
	for i := 0; i < keyBuilder.Desc.Count(); i++ {
		firstRow[i], err = tree.GetField(ctx, prollyMap.KeyDesc(), i, firstKey, prollyMap.NodeStore())
		if err != nil {
			return nil, err
		}
	}
	return firstRow, nil
}