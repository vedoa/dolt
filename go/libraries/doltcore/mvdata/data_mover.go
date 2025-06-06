// Copyright 2019 Dolthub, Inc.
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

package mvdata

import (
	"context"
	"errors"
	"fmt"

	sqle "github.com/dolthub/go-mysql-server"
	"github.com/dolthub/go-mysql-server/sql"

	"github.com/dolthub/dolt/go/cmd/dolt/errhand"
	"github.com/dolthub/dolt/go/libraries/doltcore/doltdb"
	"github.com/dolthub/dolt/go/libraries/doltcore/env/actions"
	"github.com/dolthub/dolt/go/libraries/doltcore/schema"
	"github.com/dolthub/dolt/go/libraries/doltcore/sqle/sqlutil"
	"github.com/dolthub/dolt/go/libraries/doltcore/table"
	"github.com/dolthub/dolt/go/libraries/utils/filesys"
	"github.com/dolthub/dolt/go/libraries/utils/set"
)

type CsvOptions struct {
	Delim string
}

type XlsxOptions struct {
	SheetName string
}

type JSONOptions struct {
	TableName string
	SchFile   string
	SqlCtx    *sql.Context
	Engine    *sqle.Engine
}

type ParquetOptions struct {
	TableName string
	SchFile   string
	SqlCtx    *sql.Context
	Engine    *sqle.Engine
}

type MoverOptions struct {
	ContinueOnErr  bool
	Force          bool
	TableToWriteTo string
	Operation      TableImportOp
	DisableFks     bool
}

type DataMoverOptions interface {
	IsAutocommitOff() bool
	IsBatched() bool
	WritesToTable() bool
	SrcName() string
	DestName() string
}

type DataMoverCreationErrType string

const (
	CreateReaderErr   DataMoverCreationErrType = "Create reader error"
	NomsKindSchemaErr DataMoverCreationErrType = "Invalid schema error"
	SchemaErr         DataMoverCreationErrType = "Schema error"
	MappingErr        DataMoverCreationErrType = "Mapping error"
	ReplacingErr      DataMoverCreationErrType = "Replacing error"
	CreateMapperErr   DataMoverCreationErrType = "Mapper creation error"
	CreateWriterErr   DataMoverCreationErrType = "Create writer error"
	CreateSorterErr   DataMoverCreationErrType = "Create sorter error"
)

var ErrProvidedPkNotFound = errors.New("provided primary key not found")

type DataMoverCreationError struct {
	ErrType DataMoverCreationErrType
	Cause   error
}

func (dmce *DataMoverCreationError) String() string {
	return string(dmce.ErrType) + ": " + dmce.Cause.Error()
}

// SchAndTableNameFromFile reads a SQL schema file and creates a Dolt schema from it.
func SchAndTableNameFromFile(ctx *sql.Context, path string, fs filesys.Filesys, root doltdb.RootValue, engine *sqle.Engine) (string, schema.Schema, error) {
	if path != "" {
		data, err := fs.ReadFile(path)
		if err != nil {
			return "", nil, err
		}

		tn, sch, err := sqlutil.ParseCreateTableStatement(ctx, root, engine, string(data))

		if err != nil {
			return "", nil, fmt.Errorf("%s in schema file %s", err.Error(), path)
		}

		return tn, sch, nil
	} else {
		return "", nil, errors.New("no schema file to parse")
	}
}

func InferSchema(ctx context.Context, root doltdb.RootValue, rd table.ReadCloser, tableName string, pks []string, args actions.InferenceArgs) (schema.Schema, error) {
	var err error

	infCols, err := actions.InferColumnTypesFromTableReader(ctx, rd, args)
	if err != nil {
		return nil, err
	}

	pkSet := set.NewStrSet(pks)
	newCols := schema.MapColCollection(infCols, func(col schema.Column) schema.Column {
		col.IsPartOfPK = pkSet.Contains(col.Name)
		if col.IsPartOfPK {
			hasNotNull := false
			for _, constraint := range col.Constraints {
				if _, ok := constraint.(schema.NotNullConstraint); ok {
					hasNotNull = true
					break
				}
			}
			if !hasNotNull {
				col.Constraints = append(col.Constraints, schema.NotNullConstraint{})
			}
		}
		return col
	})

	// check that all provided primary keys are being used
	for _, pk := range pks {
		col, ok := newCols.GetByName(pk)
		if !col.IsPartOfPK || !ok {
			return nil, ErrProvidedPkNotFound
		}
	}

	// NOTE: This code is only used in the import codepath for Dolt, so we don't use a schema to qualify the table name
	newCols, err = doltdb.GenerateTagsForNewColColl(ctx, root, tableName, newCols)
	if err != nil {
		return nil, errhand.BuildDError("failed to generate new schema").AddCause(err).Build()
	}

	err = schema.ValidateForInsert(newCols)
	if err != nil {
		return nil, errhand.BuildDError("invalid schema").AddCause(err).Build()
	}

	return schema.SchemaFromCols(newCols)
}

type TableImportOp string

const (
	CreateOp  TableImportOp = "overwrite"
	ReplaceOp TableImportOp = "replace"
	UpdateOp  TableImportOp = "update"
	AppendOp  TableImportOp = "append"
)
