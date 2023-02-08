import { getArgs } from "../helpers.js";

const { dbName } = getArgs();

export const databaseTests = [
  {
    q: `USE ::dbName`,
    p: { dbName: `${dbName}/main` },
    res: {
      fieldCount: 0,
      affectedRows: 0,
      insertId: 0,
      info: "",
      serverStatus: 2,
      warningStatus: 0,
    },
  },
  {
    q: `SHOW DATABASES`,
    res: [
      { Database: "information_schema" },
      { Database: "mysql" },
      { Database: `${dbName}` },
      { Database: `${dbName}/main` },
    ],
  },
  {
    q: `CREATE DATABASE ::dbName`,
    p: { dbName: "new_db" },
    res: {
      fieldCount: 0,
      affectedRows: 1,
      insertId: 0,
      info: "",
      serverStatus: 2,
      warningStatus: 0,
    },
  },
  {
    q: `SHOW DATABASES`,
    res: [
      { Database: "information_schema" },
      { Database: "mysql" },
      { Database: `${dbName}` },
      { Database: `${dbName}/main` },
      { Database: "new_db" },
    ],
  },
];
