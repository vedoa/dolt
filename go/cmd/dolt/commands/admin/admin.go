// Copyright 2022 Dolthub, Inc.
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

package admin

import (
	"github.com/dolthub/dolt/go/cmd/dolt/cli"
	"github.com/dolthub/dolt/go/cmd/dolt/commands/admin/createchunk"
)

var Commands = cli.NewHiddenSubCommandHandler("admin", "Commands for directly working with Dolt storage for purposes of testing or database recovery", []cli.Command{
	SetRefCmd{},
	ShowRootCmd{},
	ZstdCmd{},
	StorageCmd{},
	NewGenToOldGenCmd{},
	ConjoinCmd{},
	createchunk.Commands,
})
