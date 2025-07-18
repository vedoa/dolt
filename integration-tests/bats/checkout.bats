#!/usr/bin/env bats
load $BATS_TEST_DIRNAME/helper/common.bash

setup() {
    setup_common
}

teardown() {
    teardown_common
}

export NO_COLOR=1

@test "checkout: dolt checkout takes working set changes with you" {
    dolt sql <<SQL
create table test(a int primary key);
insert into test values (1);
SQL
    dolt add .

    dolt commit -am "Initial table with one row"
    dolt branch feature

    dolt sql -q "insert into test values (2)"
    dolt checkout feature

    run dolt sql -q "select count(*) from test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2" ]] || false

    run dolt status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "modified" ]] || false

    dolt checkout main

    run dolt sql -q "select count(*) from test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2" ]] || false

    run dolt status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "modified" ]] || false

    # Making additional changes to main, should carry them to feature without any problem
    dolt sql -q "insert into test values (3)"
    dolt checkout feature

    run dolt sql -q "select count(*) from test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "3" ]] || false

    run dolt status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "modified" ]] || false
}

@test "checkout: dolt checkout takes working set changes with you on new table" {
    dolt sql <<SQL
create table test(a int primary key);
insert into test values (1);
SQL
    dolt add . && dolt commit -am "Initial table with one row"
    dolt branch feature

    dolt sql -q "create table t2(b int primary key)"
    dolt sql -q "insert into t2 values (1);"

    # This is fine for an untracked table, takes it to the new branch with you
    dolt checkout feature

    run dolt sql -q "select count(*) from t2"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1" ]] || false

    run dolt status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "new table" ]] || false

    dolt checkout main

    run dolt sql -q "select count(*) from t2"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1" ]] || false

    run dolt status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "new table" ]] || false

    # Now check the table into main and make additional changes
    dolt add . && dolt commit -m "new table"
    dolt sql -q "insert into t2 values (2);"

    # This is an error, matching git (cannot check out a branch that lacks a
    # file you have modified)
    run dolt checkout feature
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Your local changes to the following tables would be overwritten by checkout" ]] || false
    [[ "$output" =~ "t2" ]] || false 
}

@test "checkout: checkout would overwrite local changes" {
    dolt sql <<SQL
create table test(a int primary key);
insert into test values (1);
SQL
    dolt add .

    dolt commit -am "Initial table with one row"
    dolt checkout -b feature

    dolt sql -q "insert into test values (2)"
    dolt commit -am "inserted a value"
    dolt checkout main

    dolt sql -q "insert into test values (3)"
    run dolt checkout feature

    [ "$status" -ne 0 ]
    [[ "$output" =~ "Your local changes to the following tables would be overwritten by checkout" ]] || false
    [[ "$output" =~ "test" ]] || false 
}

@test "checkout: dolt checkout doesn't stomp working set changes on other branch" {
    dolt sql <<SQL
create table test(a int primary key);
insert into test values (1);
SQL

    dolt add .
    dolt commit -am "Initial table with one row"
    dolt branch feature

    dolt sql  <<SQL
call dolt_checkout('feature');
insert into test values (2);
SQL

    # With no uncommitted working set changes, this works fine (no
    # working set comes with us, we get the working set of the feature
    # branch instead)
    run dolt checkout feature
    [ "$status" -eq 0 ]
 
    run dolt sql -q "select count(*) from test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2" ]] || false

    # These working set changes come with us when we change back to main
    dolt checkout main
    run dolt sql -q "select count(*) from test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2" ]] || false

    # Reset our test setup
    dolt sql  <<SQL
call dolt_checkout('feature');
call dolt_reset('--hard');
insert into test values (3);
SQL

    # With a dirty working set on the other branch, dolt checkout should fail
    run dolt checkout feature
    [ "$status" -eq 1 ]
    [[ "$output" =~ "checkout would overwrite uncommitted changes" ]] || false

    # Same as above, but changes are staged, not in working
    dolt sql  <<SQL
call dolt_checkout('feature');
call dolt_reset('--hard');
insert into test values (3);
call dolt_add('.');
SQL

    run dolt checkout feature
    [ "$status" -eq 1 ]
    [[ "$output" =~ "checkout would overwrite uncommitted changes" ]] || false

    # Same as above, but changes are staged and working
    dolt add .
    dolt sql  <<SQL
call dolt_checkout('feature');
call dolt_reset('--hard');
insert into test values (3);
call dolt_add('.');
insert into test values (4);
SQL

    run dolt checkout feature
    [ "$status" -eq 1 ]
    [[ "$output" =~ "checkout would overwrite uncommitted changes" ]] || false
    
    dolt reset --hard
    dolt sql -q "insert into test values (3)"
    dolt add .
    dolt sql -q "insert into test values (4)"
    
    # with staged changes matching on both branches, permit the checkout
    dolt checkout feature
    run dolt sql -q "select count(*) from test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "3" ]] || false
}

@test "checkout: dolt checkout table to restore working tree tables with add and drop foreign key" {
    dolt sql -q "create table t (c1 int primary key, c2 int, check(c2 > 0))"
    dolt sql -q "create table z (c1 int primary key, c2 int)"
    dolt commit -Am "create tables t and z"

    dolt sql -q "ALTER TABLE z ADD CONSTRAINT foreign_key1 FOREIGN KEY (c1) references t(c1)"
    run dolt status
    [[ "$output" =~ "Changes not staged for commit:" ]] || false
    [[ "$output" =~ "modified:         z" ]] || false

    run dolt schema show z
    [ "$status" -eq 0 ]
    [[ "$output" =~ "foreign_key1" ]] || false

    dolt checkout z

    run dolt status
    [[ "$output" =~ "On branch main" ]] || false
    [[ "$output" =~ "nothing to commit, working tree clean" ]] || false

    run dolt schema show z
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "foreign_key1" ]] || false

    dolt sql -q "ALTER TABLE z ADD CONSTRAINT foreign_key1 FOREIGN KEY (c1) references t(c1)"
    dolt commit -am "add fkey"

    dolt sql -q "alter table z drop constraint foreign_key1"
    run dolt status
    [[ "$output" =~ "Changes not staged for commit:" ]] || false
    [[ "$output" =~ "modified:         z" ]] || false

    run dolt schema show z
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "foreign_key1" ]] || false

    dolt checkout z

    run dolt status
    [[ "$output" =~ "On branch main" ]] || false
    [[ "$output" =~ "nothing to commit, working tree clean" ]] || false

    run dolt schema show z
    [ "$status" -eq 0 ]
    [[ "$output" =~ "foreign_key1" ]] || false
}

@test "checkout: dolt checkout table from another branch" {
    dolt sql -q "create table t (c1 int primary key, c2 int, check(c2 > 0))"
    dolt sql -q "create table z (c1 int primary key, c2 int)"
    dolt sql -q "insert into t values (1,1)"
    dolt sql -q "insert into z values (2,2);"
    dolt commit -Am "new values in t"    
    dolt branch b1
    dolt sql -q "insert into t values (3,3);"
    dolt sql -q "insert into z values (4,4);"
    dolt checkout b1 -- t

    dolt status
    run dolt status
    [[ "$output" =~ "On branch main" ]] || false
    [[ "$output" =~ "modified:         z" ]] || false
    [[ ! "$output" =~ "modified:         t" ]] || false

    run dolt sql -q "select count(*) from t" -r csv
    [[ "$output" =~ "1" ]] || false

    run dolt sql -q "select count(*) from z" -r csv
    [[ "$output" =~ "2" ]] || false
}

@test "checkout: with -f flag without conflict" {
    dolt sql -q 'create table test (id int primary key);'
    dolt sql -q 'insert into test (id) values (8);'
    dolt add .
    dolt commit -m 'create test table.'

    dolt checkout -b branch1
    dolt sql -q 'insert into test (id) values (1), (2), (3);'
    dolt add .
    dolt commit -m 'add some values to branch 1.'

    run dolt checkout -f main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Switched to branch 'main'" ]] || false

    run dolt sql -q "select * from test;"
    [[ "$output" =~ "8" ]] || false
    [[ ! "$output" =~ "1" ]] || false
    [[ ! "$output" =~ "2" ]] || false
    [[ ! "$output" =~ "3" ]] || false

    dolt checkout branch1
    run dolt sql -q "select * from test;"
    [[ "$output" =~ "1" ]] || false
    [[ "$output" =~ "2" ]] || false
    [[ "$output" =~ "3" ]] || false
    [[ "$output" =~ "8" ]] || false
}

@test "checkout: with -f flag with conflict" {
    dolt sql -q 'create table test (id int primary key);'
    dolt sql -q 'insert into test (id) values (8);'
    dolt add .
    dolt commit -m 'create test table.'

    dolt checkout -b branch1
    dolt sql -q 'insert into test (id) values (1), (2), (3);'
    dolt add .
    dolt commit -m 'add some values to branch 1.'

    dolt sql -q 'insert into test (id) values (4);'
    run dolt checkout main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Please commit your changes or stash them before you switch branches." ]] || false

    # Still on main
    run dolt status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "branch1" ]] || false

    run dolt checkout -f main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Switched to branch 'main'" ]] || false

    run dolt sql -q "select * from test;"
    [[ "$output" =~ "8" ]] || false
    [[ ! "$output" =~ "4" ]] || false

    dolt checkout branch1
    run dolt sql -q "select * from test;"
    [[ "$output" =~ "1" ]] || false
    [[ "$output" =~ "2" ]] || false
    [[ "$output" =~ "3" ]] || false
    [[ "$output" =~ "8" ]] || false
    [[ ! "$output" =~ "4" ]] || false
}

@test "checkout: -B flag will forcefully reset an existing branch" {
    dolt sql -q 'create table test (id int primary key);'
    dolt sql -q 'insert into test (id) values (89012);'
    dolt commit -Am 'first change.'
    dolt sql -q 'insert into test (id) values (76543);'
    dolt commit -Am 'second change.'

    dolt checkout -b testbr main~1
    run dolt sql -q "select * from test;"
    [[ "$output" =~ "89012" ]] || false
    [[ ! "$output" =~ "76543" ]] || false

    # make a change to the branch which we'll lose
    dolt sql -q 'insert into test (id) values (19283);'
    dolt commit -Am 'change to testbr.'

    dolt checkout main
    dolt checkout -B testbr main
    run dolt sql -q "select * from test;"
    [[ "$output" =~ "89012" ]] || false
    [[ "$output" =~ "76543" ]] || false
    [[ ! "$output" =~ "19283" ]] || false
}

@test "checkout: -B will create a branch that does not exist" {
    dolt sql -q 'create table test (id int primary key);'
    dolt sql -q 'insert into test (id) values (89012);'
    dolt commit -Am 'first change.'
    dolt sql -q 'insert into test (id) values (76543);'
    dolt commit -Am 'second change.'

    dolt checkout -B testbr main~1
    run dolt sql -q "select * from test;"
    [[ "$output" =~ "89012" ]] || false
    [[ ! "$output" =~ "76543" ]] || false
}

@test "checkout: attempting to checkout a detached head shows a suggestion instead" {
  dolt sql -q "create table test (id int primary key);"
  dolt add .
  dolt commit -m "create test table."
  sha=$(dolt log --oneline --decorate=no | head -n 1 | cut -d ' ' -f 1)

  # remove special characters (color)
  sha=$(echo $sha | sed -E "s/[[:cntrl:]]\[[0-9]{1,3}m//g")

  run dolt checkout "$sha"
  [ "$status" -ne 0 ]
  cmd=$(echo "${lines[1]}" | cut -d ' ' -f 1,2,3)
  [[ $cmd =~ "dolt checkout $sha" ]] || false
}

@test "checkout: commit --amend only changes commit message" {
  dolt sql -q "create table test (id int primary key);"
  dolt sql -q 'insert into test (id) values (8);'
  dolt add .
  dolt commit -m "original commit message"

  dolt commit --amend -m "modified_commit_message"

  commitmsg=$(dolt log --oneline | head -n 1)
  [[ $commitmsg =~ "modified_commit_message" ]] || false

  numcommits=$(dolt log --oneline | wc -l)
  [[ $numcommits =~ "2" ]] || false

  run dolt sql -q 'select * from test;'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "8" ]] || false
}

@test "checkout: commit --amend adds new changes to existing commit" {
  dolt sql -q "create table test (id int primary key);"
  dolt sql -q 'insert into test (id) values (8);'
  dolt add .
  dolt commit -m "original commit message"

  dolt sql -q 'insert into test (id) values (9);'
  dolt add .
  dolt commit --amend -m "modified_commit_message"

  commitmsg=$(dolt log --oneline | head -n 1)
  [[ $commitmsg =~ "modified_commit_message" ]] || false

  numcommits=$(dolt log --oneline | wc -l)
  [[ $numcommits =~ "2" ]] || false

  run dolt sql -q 'select * from test;'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "8" ]] || false
  [[ "$output" =~ "9" ]] || false
}

@test "checkout: commit --amend on merge commits does not modify metadata of merged parents" {
  dolt sql -q "create table test (id int primary key, id2 int);"
  dolt add .
  dolt commit -m "original table"

  dolt checkout -b test-branch
  dolt sql -q 'insert into test (id, id2) values (0, 2);'
  dolt add .
  dolt commit -m "conflicting commit message"

  shaparent1=$(dolt log --oneline --decorate=no | head -n 1 | cut -d ' ' -f 1)
  # remove special characters (color)
  shaparent1=$(echo $shaparent1 | sed -E "s/[[:cntrl:]]\[[0-9]{1,3}m//g")

  dolt checkout main
  dolt sql -q 'insert into test (id, id2) values (0, 1);'
  dolt add .
  dolt commit -m "original commit message"
  shaparent2=$(dolt log --oneline --decorate=no | head -n 1 | cut -d ' ' -f 1)
  # remove special characters (color)
  shaparent2=$(echo $shaparent2 | sed -E "s/[[:cntrl:]]\[[0-9]{1,3}m//g")

  run dolt merge test-branch
  [ "$status" -eq 1 ]
  [[ "$output" =~ "CONFLICT (content):" ]] || false
  dolt conflicts resolve --theirs .
  dolt commit -m "final merge"

  dolt commit --amend -m "new merge"
  commitmeta=$(dolt log --oneline --parents | head -n 1)
  [[ "$commitmeta" =~ "$shaparent1" ]] || false
  [[ "$commitmeta" =~ "$shaparent2" ]] || false
}

@test "checkout: dolt_commit --amend on merge commits does not modify metadata of merged parents" {
  dolt sql -q "create table test (id int primary key, id2 int);"
  dolt add .
  dolt commit -m "original table"

  dolt checkout -b test-branch
  dolt sql -q 'insert into test (id, id2) values (0, 2);'
  dolt add .
  dolt commit -m "conflicting commit message"

  shaparent1=$(dolt log --oneline --decorate=no | head -n 1 | cut -d ' ' -f 1)
  # remove special characters (color)
  shaparent1=$(echo $shaparent1 | sed -E "s/[[:cntrl:]]\[[0-9]{1,3}m//g")

  dolt checkout main
  dolt sql -q 'insert into test (id, id2) values (0, 1);'
  dolt add .
  dolt commit -m "original commit message"
  shaparent2=$(dolt log --oneline --decorate=no | head -n 1 | cut -d ' ' -f 1)
  # remove special characters (color)
  shaparent2=$(echo $shaparent2 | sed -E "s/[[:cntrl:]]\[[0-9]{1,3}m//g")

  run dolt merge test-branch
  [ "$status" -eq 1 ]
  echo "$output"
  [[ "$output" =~ "CONFLICT (content):" ]] || false
  dolt conflicts resolve --theirs .
  dolt commit -m "final merge"

  dolt sql -q "call dolt_commit('--amend', '-m', 'new merge');"
  commitmeta=$(dolt log --oneline --parents | head -n 1)
  [[ "$commitmeta" =~ "$shaparent1" ]] || false
  [[ "$commitmeta" =~ "$shaparent2" ]] || false
}


@test "checkout: dolt_checkout brings in changes from main to feature branch that has no working set" {
  # original setup
  dolt sql -q "create table users (id int primary key, name varchar(32));"
  dolt add .
  dolt commit -m "original users table"

  # create feature branch
  dolt branch -c main feature

  # make changes on main and verify
  dolt sql -q 'insert into users (id, name) values (1, "main-change");'
  run dolt sql -q "select name from users"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false

  # checkout feature branch and bring over main changes
  dolt checkout feature

  # verify working set changes are brought in from main
  run dolt sql << SQL
call dolt_checkout('feature');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false

  # verify working set changes are not on main
  run dolt sql << SQL
call dolt_checkout('main');
select count(*) from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false

  # revert working set changes on feature branch
  dolt reset --hard HEAD
  run dolt sql -q "select count(*) from users"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false

  # switch to main and verify working set changes are not present
  dolt checkout main
  run dolt sql -q "select count(*) from users"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false
}

@test "checkout: dolt_checkout switches from clean main to feature branch that has changes" {
  # original setup
  dolt sql -q "create table users (id int primary key, name varchar(32));"
  dolt add .
  dolt commit -m "original users table"

  # create feature branch
  dolt branch -c main feature

  # make changes on feature (through SQL)
  dolt sql << SQL
call dolt_checkout('feature');
insert into users (id, name) values (1, "feature-change");
SQL

  # verify feature branch changes are present
  run dolt sql << SQL
call dolt_checkout('feature');
select name from users;
SQL
  echo "output = $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "feature-change" ]] || false

  # checkout feature branch
  dolt checkout feature

  # verify feature's working set changes are gone
  run dolt sql << SQL
call dolt_checkout('feature');
select count(*) from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false

  # verify working set changes are not on main
  run dolt sql << SQL
call dolt_checkout('main');
select count(*) from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false
}

@test "checkout: dolt_checkout brings in changes from main to feature branch that has identical changes" {
  # original setup
  dolt sql -q "create table users (id int primary key, name varchar(32));"
  dolt add .
  dolt commit -m "original users table"

  # create feature branch
  dolt branch -c main feature

  # make changes on main and verify
  dolt sql -q 'insert into users (id, name) values (1, "main-change");'
  run dolt sql -q "select name from users"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false

  # make identical changes on feature (through SQL)
  dolt sql << SQL
call dolt_checkout('feature');
insert into users (id, name) values (1, "main-change");
SQL

  # verify feature branch changes are present
  run dolt sql << SQL
call dolt_checkout('feature');
select name from users;
SQL
  echo "output = $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false

  # checkout feature branch
  dolt checkout feature

  # verify working set changes are still the same on feature branch
  run dolt sql << SQL
call dolt_checkout('feature');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false

  # verify working set changes are not on main
  run dolt sql << SQL
call dolt_checkout('main');
select count(*) from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false

  # revert working set changes on feature branch
  dolt reset --hard HEAD

  # verify working set changes are not on feature branch
  run dolt sql << SQL
call dolt_checkout('feature');
select count(*) from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false

  # switch to main and verify working set changes are not present
  dolt checkout main
  run dolt sql << SQL
call dolt_checkout('main');
select count(*) from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false
}

@test "checkout: dolt_checkout needs -f to bring in changes from main to feature branch that has different changes" {
  # original setup
  dolt sql -q "create table users (id int primary key, name varchar(32));"
  dolt add .
  dolt commit -m "original users table"

  # create feature branch from main
  dolt branch feature

  # make changes on main and verify
  dolt sql -q 'insert into users (id, name) values (1, "main-change");'
  run dolt sql -q "select name from users"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false

  # make different changes on feature (through SQL)
  dolt sql << SQL
call dolt_checkout('feature');
insert into users (id, name) values (2, "feature-change");
SQL

  # verify feature branch changes are present
  run dolt sql << SQL
call dolt_checkout('feature');
select name from users;
SQL
  echo "output = $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "feature-change" ]] || false

  # checkout feature branch: should fail due to working set changes
  run dolt checkout feature
  echo "output = $output"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "checkout would overwrite uncommitted changes on target branch" ]] || false

  # force checkout feature branch
  dolt checkout -f feature

  # verify working set changes on feature are from main
  run dolt sql << SQL
call dolt_checkout('feature');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false

  # verify working set changes are not on main
  run dolt sql << SQL
call dolt_checkout('main');
select count(*) from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0" ]] || false
}

@test "checkout: dolt_checkout brings changes from main to multiple feature branches and back to main" {
  # original setup
  dolt sql -q "create table users (id int primary key, name varchar(32));"
  dolt add .
  dolt commit -m "original users table"


  # make changes on main and verify
  dolt sql -q 'insert into users (id, name) values (0, "main-change");'
  run dolt sql << SQL
call dolt_checkout('main');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false


  # create feature1 branch and bring changes to the new feature branch
  dolt checkout -b feature1

  # verify the changes are brought to feature1
  run dolt sql << SQL
call dolt_checkout('feature1');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false


  # make changes on feature1 and verify
  dolt sql -q 'insert into users (id, name) values (1, "feature1-change");'
  run dolt sql << SQL
call dolt_checkout('feature1');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false
  [[ "$output" =~ "feature1-change" ]] || false

  # create feature2 branch and bring changes to next feature branch
  dolt checkout -b feature2

  # verify the changes are brought to feature1
  run dolt sql << SQL
call dolt_checkout('feature2');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false
  [[ "$output" =~ "feature1-change" ]] || false

  # make changes on feature2 and verify
  dolt sql -q 'insert into users (id, name) values (2, "feature2-change");'
  run dolt sql << SQL
call dolt_checkout('feature2');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false
  [[ "$output" =~ "feature1-change" ]] || false
  [[ "$output" =~ "feature2-change" ]] || false


  # bring changes back to main
  dolt checkout main

  # verify the changes are brought to main
  run dolt sql << SQL
call dolt_checkout('main');
select name from users
SQL
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main-change" ]] || false
  [[ "$output" =~ "feature1-change" ]] || false
  [[ "$output" =~ "feature2-change" ]] || false

}

@test "checkout: table and branch name conflict with -- separator" {
    # setup a table with the same name as a branch we'll create
    dolt sql -q "create table feature (id int primary key, value int);"
    dolt sql -q "insert into feature values (1, 100);"
    dolt add .
    dolt commit -m "Add feature table"

    # create a branch with the same name as the table
    dolt checkout -b feature

    dolt sql -q "insert into feature values (2, 200);"
    dolt add .
    dolt commit -m "Add row to feature table"

    dolt checkout main

    # modify the feature table
    dolt sql -q "update feature set value = 101 where id = 1;"

    # use -- to explicitly indicate we want to checkout the table, not the branch
    run dolt checkout -- feature

    # verify the table was reset (not switched to feature branch)
    run dolt sql -q "select * from feature;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,100" ]] || false
    [[ ! "$output" =~ "101" ]] || false

    # verify we're still on main branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* main" ]] || false
}

@test "checkout: explicit branch checkout with -- separator" {
    # setup a table with the same name as a branch
    dolt sql -q "create table feature (id int primary key, value int);"
    dolt sql -q "insert into feature values (1, 100);"
    dolt add .
    dolt commit -m "Add feature table"

    # create a branch with the same name as the table
    dolt checkout -b feature
    dolt sql -q "update feature set value = 200 where id = 1;"
    dolt add .
    dolt commit -m "Update feature value on feature branch"

    dolt checkout main

    # use explicit branch reference
    dolt checkout feature --

    # verify we switched to feature branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* feature" ]] || false

    # verify we have the feature branch version of the table
    run dolt sql -q "select * from feature;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,200" ]] || false
}

@test "checkout: checkout specific table from branch" {
    # setup tables
    dolt sql -q "create table users (id int primary key, name varchar(50));"
    dolt sql -q "create table products (id int primary key, name varchar(50));"
    dolt sql -q "insert into users values (1, 'Alice');"
    dolt sql -q "insert into products values (1, 'Widget');"
    dolt add .
    dolt commit -m "Add initial tables"

    # create a branch with different data
    dolt checkout -b feature
    dolt sql -q "update users set name = 'Bob' where id = 1;"
    dolt sql -q "update products set name = 'Gadget' where id = 1;"
    dolt add .
    dolt commit -m "Update data on feature branch"

    dolt checkout main

    # checkout only the users table from feature branch
    dolt checkout feature -- users

    # verify we got the users table from feature branch
    run dolt sql -q "select * from users;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,Bob" ]] || false

    # verify products table is still from main
    run dolt sql -q "select * from products;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,Widget" ]] || false

    # verify we're still on main
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* main" ]] || false
}

@test "checkout: remote tracking branch shorthand" {
    mkdir -p remote-repo
    mkdir -p local-repo
    cd local-repo
    dolt init
    dolt remote add origin file://../remote-repo
    dolt push -u origin main

    # setup initial commit
    dolt sql -q "create table test (id int primary key, val int);"
    dolt sql -q "insert into test values (1, 100);"
    dolt add .
    dolt commit -m "Initial commit"

    # create a feature branch and push
    dolt checkout -b feature
    dolt sql -q "update test set val = 200 where id = 1;"
    dolt add .
    dolt commit -m "Update on feature branch"
    dolt push origin feature

    # verify the remote tracking branch exists
    run dolt branch -a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "remotes/origin/feature" ]] || false

    # use DWIM to checkout and create a local branch from remote tracking branch
    dolt checkout main
    dolt branch -D feature  # delete local feature branch if it exists
    dolt checkout feature

    # verify we're now on a local feature branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* feature" ]] || false

    # verify the data from the feature branch
    run dolt sql -q "select * from test;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,200" ]] || false
}

@test "checkout: error on ambiguous name matching tracking branch and table" {
    mkdir -p remote-repo
    mkdir -p local-repo
    cd local-repo
    dolt init
    dolt remote add origin file://../remote-repo
    dolt push -u origin main

    # create a branch called 'feature' on the remote
    dolt sql -q "create table test (id int primary key, val int);"
    dolt sql -q "insert into test values (1, 50);"
    dolt add .
    dolt commit -m "Initial commit"
    dolt push origin main
    dolt checkout -b feature
    dolt sql -q "update test set val = 200 where id = 1;"
    dolt add .
    dolt commit -m "Update on feature branch"
    dolt push origin feature

    # verify remote tracking branch exists
    run dolt branch -a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "remotes/origin/feature" ]] || false

    # create a table with the same name as the tracking branch
    dolt checkout main
    dolt sql -q "create table feature (id int primary key, value int);"
    dolt sql -q "insert into feature values (1, 100);"
    dolt add .
    dolt commit -m "Create table with same name as tracking branch"

    # try to checkout "feature" without disambiguation
    # this should fail because it could refer to either the table or the tracking branch
    dolt branch -D feature  # delete local branch since this only happens when it does not exist
    run dolt checkout feature
    [ "$status" -ne 0 ]
    [[ "$output" =~ "could be both a local table and a tracking branch" ]] || false
    [[ "$output" =~ "Please use -- to disambiguate" ]] || false

    # verify we're still on main
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* main" ]] || false

    # test that we can disambiguate with -- for the table
    dolt checkout -- feature

    # verify table was restored from HEAD
    run dolt sql -q "select * from feature;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,100" ]] || false

    # test that we can disambiguate for the branch using --
    dolt checkout feature --

    # verify we're now on a local feature branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* feature" ]] || false
}

@test "checkout: default to local branch checkout after disambiguation" {
    mkdir -p remote-repo
    mkdir -p local-repo
    cd local-repo
    dolt init
    dolt remote add origin file://../remote-repo
    dolt push -u origin main

    # create a branch called 'feature' on the remote
    dolt sql -q "create table test (id int primary key, val int);"
    dolt sql -q "insert into test values (1, 50);"
    dolt add .
    dolt commit -m "Initial commit"
    dolt push origin main
    dolt checkout -b feature
    dolt sql -q "update test set val = 200 where id = 1;"
    dolt add .
    dolt commit -m "Update on feature branch"
    dolt push origin feature

    # verify remote tracking branch exists
    run dolt branch -a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "remotes/origin/feature" ]] || false

    # create a table with the same name as the tracking branch
    dolt checkout main
    dolt sql -q "create table feature (id int primary key, value int);"
    dolt sql -q "insert into feature values (1, 100);"
    dolt add .
    dolt commit -m "Create table with same name as tracking branch"

    # try to checkout "feature" without disambiguation
    # this should fail because it could refer to either the table or the tracking branch
    dolt branch -D feature  # delete local branch since this only happens when it does not exist

    # test that we can disambiguate for the branch using --
    dolt checkout feature --

    # verify we're now on a local feature branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* feature" ]] || false

    run dolt checkout main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Switched to branch 'main'" ]] || false

    run dolt checkout feature
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Switched to branch 'feature'" ]] || false
}

@test "checkout: error with multiple refs using --" {
    # setup branches and tables
    dolt sql -q "create table feature (id int primary key, value int);"
    dolt add .
    dolt commit -m "Add feature table"

    # create multiple branches
    dolt branch branch1
    dolt branch branch2

    # attempt to checkout with multiple refs, which should fail
    run dolt checkout branch1 branch2 -- feature
    [ "$status" -ne 0 ]
    [[ "$output" =~ "only one reference" ]] || false

    # verify we're still on main branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* main" ]] || false
}

@test "checkout: checkout multiple tables using --" {
    # setup multiple tables
    dolt sql -q "create table table1 (id int primary key, value int);"
    dolt sql -q "create table table2 (id int primary key, name varchar(50));"
    dolt sql -q "insert into table1 values (1, 100);"
    dolt sql -q "insert into table2 values (1, 'original');"
    dolt add .
    dolt commit -m "Add initial tables"

    # create feature branch with modifications to both tables
    dolt checkout -b feature
    dolt sql -q "update table1 set value = 200 where id = 1;"
    dolt sql -q "update table2 set name = 'modified' where id = 1;"
    dolt add .
    dolt commit -m "Update tables on feature branch"

    # go back to main and make different changes
    dolt checkout main
    dolt sql -q "update table1 set value = 150 where id = 1;"
    dolt sql -q "update table2 set name = 'changed' where id = 1;"

    # checkout multiple tables from feature branch
    dolt checkout feature -- table1 table2

    # verify both tables were updated from feature branch
    run dolt sql -q "select * from table1;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,200" ]] || false

    run dolt sql -q "select * from table2;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,modified" ]] || false

    # verify we're still on main branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* main" ]] || false
}

@test "checkout: more than one remote share same branch name" {
    # setup two remotes with the same branch name
    mkdir -p remote1
    mkdir -p remote2
    dolt remote add origin file://remote1
    dolt remote add origin2 file://remote2

    # create a branch on both remotes
    dolt checkout -b feature
    dolt sql -q "create table test (id int primary key, value int);"
    dolt sql -q "insert into test values (1, 100);"
    dolt add .
    dolt commit -m "Add feature table"
    dolt push origin feature
    dolt push origin2 feature

    # verify both remotes have the feature branch
    run dolt branch -a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "remotes/origin/feature" ]] || false
    [[ "$output" =~ "remotes/origin2/feature" ]] || false

    dolt checkout main
    dolt branch -D feature  # delete local feature branch to cause ambiguity

    # try to checkout feature without disambiguation, should fail
    run dolt checkout feature
    [ "$status" -ne 0 ]
    echo "$output"
    [[ "$output" =~ "'feature' matched multiple (2) remote tracking branches" ]] || false

    run dolt checkout --track origin/feature
    [ "$status" -eq 0 ]
    echo "$output"
    [[ "$output" =~ "Switched to branch 'feature'" ]] || false
    [[ "$output" =~ "branch 'feature' set up to track 'origin/feature'" ]] || false

    # verify we're still on main branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* feature" ]] || false
}

@test "checkout: warning on missing table checkout" {
    # create a table and commit it
    dolt sql -q "create table test (id int primary key, value int);"
    dolt sql -q "insert into test values (1, 100);"
    dolt add .
    dolt commit -m "Add test table"

    # make modifications to existing table
    dolt sql -q "update test set value = 200 where id = 1;"

    # try to checkout a non-existent table, should fail
    run dolt checkout missing_table
    [ "$status" -ne 0 ]
    [[ "$output" =~ "tablespec 'missing_table' did not match any table(s) known to dolt" ]] || false

    # verify the existing table modifications are still present
    run dolt sql -q "select * from test;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,200" ]] || false

    # try to checkout multiple tables with one missing, should fail
    run dolt checkout -- test missing_table
    [ "$status" -ne 0 ]
    [[ "$output" =~ "tablespec 'missing_table' did not match any table(s) known to dolt" ]] || false

    # verify the existing table was checkout successfully
    run dolt sql -q "select * from test;" -r csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1,100" ]] || false

    # try to checkout multiple missing tables, should fail with multiple errors
    run dolt checkout -- missing1 missing2
    [ "$status" -ne 0 ]
    [[ "$output" =~ "tablespec 'missing1' did not match any table(s) known to dolt" ]] || false
    [[ "$output" =~ "tablespec 'missing2' did not match any table(s) known to dolt" ]] || false

    # verify we're still on main branch
    run dolt branch
    [ "$status" -eq 0 ]
    [[ "$output" =~ "* main" ]] || false
}

