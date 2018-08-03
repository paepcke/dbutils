#!/usr/bin/env bash

#----------------------------------------------------------
#
# Unit tests for the database command line interface utilities:
#
#    dbcpfrom
#    dbcpto
#    dbcplocal
#    dbmv
#    dbmvlocal
#    dbrm
#    dbrmlocal
#
# The calling user must have a --login-path set up for accessing
# MySQL. The user must also have permission to ssh into localhost
# without pwd; i.e. via key. That restriction is true for this test
# script and for the CLI tools that reach across machines. I.e. whose
# names don't end in 'local'
#
#----------------------------------------------------------


SCRIPT_NAME=$(basename $0)

MYSQL_UID=$(whoami)
USAGE="Usage: ${SCRIPT_NAME} (Calling user must have permissions for --login-path=<callingUser>)"

if [[ $# > 0 ]]
then   
   echo $USAGE
   exit 1
fi   

# Turn tabs to commas in MySQL output.
# I.e.    foo		bar 	10
#   ==>   foo,bar,10

alias mysql2csv="sed $'s/\t/,/g'"

flattenList="tr '\n' ','"


# Find a database name that doesn't exist, so that we can use it without harm:
INDX=1
UNIT_TEST_DB=UnitTests$INDX

while true
do
    RESP=$(mysql --login-path=$MYSQL_UID -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$UNIT_TEST_DB'");
    # Empty response?
    if [[ -z $RESP ]]
    then
        break
    fi
    # Exists: bump try a different name:
    INDX=$(($INDX + 1))
    UNIT_TEST_DB=UnitTests$INDX
done    

#*******************
#echo "DB name: '$UNIT_TEST_DB'"
#exit
#*******************

function setup() {
    # Ensure that table $UNIT_TEST_DB.DbTests exists:

    mysql --login-path=$MYSQL_UID -e "DROP DATABASE IF EXISTS $UNIT_TEST_DB;"
    mysql --login-path=$MYSQL_UID -e "CREATE DATABASE $UNIT_TEST_DB;"
    if [[ $? != 0 ]]
    then
        echo "Error while creating $UNIT_TEST_DB db."
        exit 1
    fi

    mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "CREATE TABLE RemoteTable (employee varchar(20), age int, department varchar(20)) engine=MyISAM"
    mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "INSERT INTO RemoteTable VALUES('smith',40,'accounting'),('miller', 50, 'hr')"
    if [[ $? != 0 ]]
    then
        echo "Error while creating table $UNIT_TEST_DB.RemoteTable."
        exit 1
    fi

}

function finalCleanup() {
    mysql --login-path=$MYSQL_UID -e "DROP DATABASE IF EXISTS $UNIT_TEST_DB;"
    exit 1
}



# Setup the db:
setup

# --------------------------------  dbcpfrom ----------------------------

# Check least complext case:
dbcpfrom --locTbl=LocalTable localhost ${MYSQL_UID} $UNIT_TEST_DB RemoteTable LocalTable

RESP=$(mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "SELECT * FROM LocalTable")
if echo $RESP | grep --silent "employee age department smith 40 accounting miller 50 hr"
then
    echo "dbcpfrom Simple copy...OK"
else
    echo "dbcpfrom Simple copy failed."
    finalCleanup
fi    

setup

# Check that won't overwrite existing local table.
# Expect Error: Table localhost.RemoteTable exists; use --backup option, or remove localhost.RemoteTable first, e.g. using dbrm RemoteTable"
RESP=$(dbcpfrom localhost ${MYSQL_UID} $UNIT_TEST_DB RemoteTable 2>&1)
if echo $RESP | grep --silent --regexp="Error.*--backup"
then
    echo "dbcpfrom: prevent overwrite...OK"
else
    echo "dbcpfrom: does not detect overwriting of local table."
    finalCleanup

fi    

setup

# Force create backup of existing table:

# Create a table just to have something to back up:
mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "CREATE TABLE LocalTable(foo int); INSERT INTO LocalTable VALUES(1);"

dbcpfrom --backup --locTbl LocalTable localhost ${MYSQL_UID} $UNIT_TEST_DB RemoteTable

# Check that we now have three tables: LocalTable, LocalTable_old1, and RemoteTable:
EXPECTED="LocalTable,LocalTable_old1,RemoteTable,"
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SHOW TABLES;" | ${flattenList})

if [[ $RESP != $EXPECTED ]]
then
    echo "dbcpfrom: make backup...Failed"
    finalCleanup
fi

# Make sure the content in LocalTable_old1 is correct:
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SELECT * FROM LocalTable_old1;")

if [[ $RESP == 1 ]]
then
    echo "dbcpfrom: make backup...OK"
else
    echo "dbcpfrom: make backup...Failed"
fi
   
#--------------------------------------- dbcplocal -------------------------------

setup

# Simple dbcplocal:

dbcplocal $MYSQL_UID $UNIT_TEST_DB RemoteTable LocalTable

# Check that we now have three tables: LocalTable, LocalTable_old1, and RemoteTable:
EXPECTED="LocalTable,RemoteTable,"
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SHOW TABLES;" | ${flattenList})

if [[ $RESP != $EXPECTED ]]
then
    echo "dbcplocal simple: not enough tables after the copy ...Failed"
    finalCleanup
else
    echo "dbcplocal simple...OK"
fi

# Using --where:

setup

dbcplocal --where 'age = 50' $MYSQL_UID $UNIT_TEST_DB RemoteTable LocalTable

# Make sure the content in LocalTable is correct:
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SELECT COUNT(*) FROM LocalTable")

if [[ $RESP != 1 ]]
then
    echo "dbcplocal using --where: incorrect number of tables after dbcplocal...Failed"
    finalCleanup
fi

RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SELECT AGE FROM LocalTable")

if [[ $RESP != 50 ]]
then
    echo "dbcplocal using --where: incorrect content in new table after dbcplocal...Failed"
    finalCleanup
else
    echo "dbcplocal using --where...OK"
fi

setup

# Create a table just to have something to back up:
mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "CREATE TABLE LocalTable(foo int); INSERT INTO LocalTable VALUES(1);"

# Check that won't overwrite existing local table.
# Expect Error: Table localhost.RemoteTable exists; use --backup option, or remove localhost.RemoteTable first, e.g. using dbrm RemoteTable"
RESP=$(dbcplocal ${MYSQL_UID} $UNIT_TEST_DB RemoteTable LocalTable 2>&1)
if echo $RESP | grep --silent --regexp="Error.*--backup"
then
    echo "dbcplocal: prevent overwrite...OK"
else
    echo "dbcplocal: does not detect overwriting of local table."
    finalCleanup

fi    

setup

# Force create backup of existing table:

# Create a table just to have something to back up:
mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "CREATE TABLE LocalTable(foo int); INSERT INTO LocalTable VALUES(1);"

dbcplocal --backup ${MYSQL_UID} $UNIT_TEST_DB RemoteTable LocalTable

# Check that we now have three tables: LocalTable, LocalTable_old1, and RemoteTable:
EXPECTED="LocalTable,LocalTable_old1,RemoteTable,"
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SHOW TABLES;" | ${flattenList})

if [[ $RESP != $EXPECTED ]]
then
    echo "dbcplocal: make backup...Failed"
    finalCleanup
fi

# Make sure the content in LocalTable_old1 is correct:
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SELECT * FROM LocalTable_old1;")

if [[ $RESP == 1 ]]
then
    echo "dbcplocal: make backup...OK"
else
    echo "dbcplocal: make backup...Failed"
fi

# --------------------------------  dbcpto ----------------------------

setup

# Check least complext case:
dbcpto --remTbl=LocalTable ${MYSQL_UID} $UNIT_TEST_DB RemoteTable ${MYSQL_UID}@127.0.0.1

RESP=$(mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "SELECT * FROM LocalTable")

if echo $RESP | grep --silent "employee age department smith 40 accounting miller 50 hr"
then
    echo "dbcpto Simple copy...OK"
else
    echo "dbcpto Simple copy failed."
    finalCleanup
fi    

setup

# Check that won't overwrite existing local table.
# Expect Error: Table localhost.RemoteTable exists; use --backup option, or remove localhost.RemoteTable first, e.g. using dbrm RemoteTable"
RESP=$(dbcpto ${MYSQL_UID} $UNIT_TEST_DB RemoteTable ${MYSQL_UID}@127.0.0.1 2>&1)
if echo $RESP | grep --silent --regexp="Error.*--backup"
then
    echo "dbcpto: prevent overwrite...OK"
else
    echo "dbcpto: does not detect overwriting of local table."
    finalCleanup

fi    

setup

# Force create backup of existing table:

# Create a table just to have something to back up:
mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "CREATE TABLE LocalTable(foo int); INSERT INTO LocalTable VALUES(1);"

dbcpto --backup --remTbl LocalTable ${MYSQL_UID} $UNIT_TEST_DB RemoteTable ${MYSQL_UID}@127.0.0.1

# Check that we now have three tables: LocalTable, LocalTable_old1, and RemoteTable:
EXPECTED="LocalTable,LocalTable_old1,RemoteTable,"
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SHOW TABLES;" | ${flattenList})

if [[ $RESP != $EXPECTED ]]
then
    echo "dbcpto: make backup...Failed"
    finalCleanup
fi

# Make sure the content in LocalTable_old1 is correct:
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SELECT * FROM LocalTable_old1;")

if [[ $RESP == 1 ]]
then
    echo "dbcpto: make backup...OK"
else
    echo "dbcpto: make backup...Failed"
fi


#--------------------------------------- dbrm -------------------------------

#Usage: dbrm [-h|--help] [-v|--verbose] [-i|--interactive] sshUser@remoteMachine remMySQLUser remDb remTbl [remTbl [remTbl]]

setup

dbrm ${MYSQL_UID}@127.0.0.1 ${MYSQL_UID} $UNIT_TEST_DB RemoteTable

# Check that we now have three tables: LocalTable, LocalTable_old1, and RemoteTable:
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SHOW TABLES;" | ${flattenList})

# Should have no tables left:
if [[ -z $RESP ]]
then
    echo "dbrm simple...OK"
else
    echo "dbrm simple...OK"    
    finalCleanup
fi

# Removing multiple tables at once:

setup

# Create a table just to have something to delete:
mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "CREATE TABLE LocalTable(foo int); INSERT INTO LocalTable VALUES(1);"

dbrm ${MYSQL_UID}@127.0.0.1 ${MYSQL_UID} $UNIT_TEST_DB RemoteTable LocalTable

# Check that we now have no tables::
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SHOW TABLES;" | ${flattenList})

# Should have no tables left:
if [[ -z $RESP ]]
then
    echo "dbrm multiple tables...OK"
else
    echo "dbrm multiple tables...Failed"    
    finalCleanup
fi


# Check the -i option: Cant' capture the question, so not implemented:

# RESP=$(dbrm -i ${MYSQL_UID}@127.0.0.1 ${MYSQL_UID} $UNIT_TEST_DB RemoteTable)

# # Response should be confirmation inquiry:
# EXPECTED="Drop table RemoteTable[yN]?"

# if [[ $RESP != $EXPECTED ]]
# then
#     echo "dbrm interactive...Failed"
# else
#     echo "dbrm interactive...OK"
# fi    

#--------------------------------------- dbrmlocal -------------------------------

setup

dbrmlocal ${MYSQL_UID} $UNIT_TEST_DB RemoteTable

# Check that we now have no tables::
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SHOW TABLES;" | ${flattenList})

# Should have no tables left:
if [[ -z $RESP ]]
then
    echo "dbrmlocal simple...OK"
else
    echo "dbrmlocal simple...Failed"    
    finalCleanup
fi

setup

# Check removing multiple tables at once:

# Create a table just to have something to delete:
mysql --login-path=$MYSQL_UID $UNIT_TEST_DB -e "CREATE TABLE LocalTable(foo int); INSERT INTO LocalTable VALUES(1);"

dbrmlocal ${MYSQL_UID} $UNIT_TEST_DB RemoteTable LocalTable

# Check that we now have no tables::
RESP=$(mysql --login-path=${MYSQL_UID} --silent --skip-column-names $UNIT_TEST_DB -e "SHOW TABLES;" | ${flattenList})

# Should have no tables left:
if [[ -z $RESP ]]
then
    echo "dbrmlocal multiple tables...OK"
else
    echo "dbrmlocal multiple tables...Failed"    
    finalCleanup
fi

finalCleanup
