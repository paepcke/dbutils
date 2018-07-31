
# Functions that support the MySQL table manipulation
# commands: dbcpfrom, dbcpto, dbmvlocal, etc. This
# file is intended to be sourced into other scripts.
# Running this file has no effect.

# Each function has a local and a remote version. The
# local version operates on a local MySQL server. The
# remote functions tunnel through SSH to the remote
# server. I.e. they do not use the mysql client's --host=
# option.


# ------------ Utility Functions For Localhost ----------


#-----------------------
# echoerr
#---------------

# Print all arguments to stderr. Used
# for error messages.

function echoerr() {
    printf "Error: %s\n" "$*" >&2;
}

#-----------------------
# echowarn
#---------------

# Print all arguments to stderr. Used
# for warning messages.

function echowarn() {
    printf "Warning: %s\n" "$*" >&2;
}

#-----------------------
# next_suffix
#---------------

function next_suffix() {

# Finds the highest number at the end of a MySQL table
# names that is not yet taken. Used for finding table
# names to save tables into. Example: Given 'my_table_old',
# and a MySQL db, the function looks through that db
# for names of the form 'my_table_old1', 'my_table_old22',
# etc. and returns the next number guaranteed to make
# a table name unique. In this case: 23.
#
# I.e. given a database_name, and a table_name_root, which 
# may or may not end with a number, retun <n> such that 
# table_name_root<n> is unique in database_name.
# OK, a funky function.
#
#  Usage:
#    NEXT_NAME=$(next_suffix mysql_user db table_name_root) 
#
# :param LOC_USER: MySQL user on local machine
# :param DATABASE: local MySQL database holding table to manipulate
# :param TABLE_NAME_ROOT: table name whose next suffix is to
#          be found.
    

  USAGE="Usage: next_suffix mysql_user mysql_db table_name_root"

  # Check parameters:
  if [[ -z $1 || -z $2 || -z $3 ]]
  then
    echoerr "Not enough args for function next_suffix: $USAGE"
    exit 1
  fi

  LOC_USER=$1
  DATABASE=$2
  TABLE_NAME_ROOT=$3

  # A query over the MySQL information schema table;
  # The '.*' matches any chars:

  read -rd '' PROBE_CMD <<EOF
  SELECT table_name 
    FROM information_schema.tables 
   WHERE table_schema = '${DATABASE}'
     AND table_name REGEXP '${TABLE_NAME_ROOT}.*';
EOF

  TBLS=$(mysql --login-path=${LOC_USER} --skip-column-names --silent ${DATABASE} -e "${PROBE_CMD}" 2>/dev/null)

  if [[ $? != 0 ]]
  then
      # Try once more with -u and no pwd:
      TBLS=$(mysql -u ${LOC_USER} --skip-column-names --silent ${DATABASE} -e "${PROBE_CMD}")
      err_code=$?
     if [[ $err_code != 0 ]]
     then
         echoerr "Error finding new table name."
         exit $err_code
     fi
  fi

  # Now might have $TBLS be: table_foo table_foo4 table_foo22
  # Goal: find the number 23

  MAX_NUM=0

  # Go through all returned tbl names, find
  # the ones that end with a number, and find
  # the highest number:

  for TBL in $TBLS
  do
      # The regex: 
      #            -n                : -n to suppress printing all patterns.
      #                                For macos must use -E instead of -R
      #            ${TABLE_NAME_ROOT}: move past the given root string
      #            \([0-9]*$\)       : find an arbitrary-length series 
      #                                of digits at the end of the name
      #                                (the '$' says end of line)
      # NOTE: The quotes MUST be double-quotes, else ${TABLE_NAME_ROOT}
      #       will not expand!

      TBL_NUM=$(echo $TBL | sed -n "s/${TABLE_NAME_ROOT}\([0-9]*$\)/\1/p")
      if [[ ${TBL_NUM} != '' && ${TBL_NUM} -gt ${MAX_NUM} ]]
      then
          # Replace old max number with new one:
          MAX_NUM=${TBL_NUM}
      fi
  done
  # Return one higher than the max number:

  echo $((${MAX_NUM} + 1))
}

#-----------------------
# db_exists
#---------------

# Echos '1' if given database exists in mysql server
# Else echos '0'.
# Usage:
#
#   EXISTS=$(db_exists mysql_user db)
#
# :param LOC_USER: MySQL user on localhost.
# :param DB: MySQL database whose existence to verify.

function db_exists() {

  if [[ $# != 2 ]]
  then
    echoerr "Not enough arguments to db_exists."
    exit 1
  fi

  LOC_USER=$1
  DB=$2

  # Note: using information_schema to check
  # for number of tables in db to be > 0
  # won't work if the db to test is empty.
  # Must use SHOW DATABASES instead
  read -r -d '' EXISTS_CMD <<EOF
       SHOW DATABASES LIKE '${DB}';
EOF

  HITS=$(mysql --login-path=${LOC_USER} -sN -e "${EXISTS_CMD}")

  if [[ $? != 0 ]]
  then
     echoerr "MySQL error while checking existence of '${DB}'. Quitting."
     exit 1
  fi

  if [[ ${HITS} == ${DB} ]]
  then
     echo 1
  else
     echo 0
  fi
} # End function db_exists


#-----------------------
# tbl_exists
#---------------

# Echos '1' if given table name exists in given db.
# Else echos '0'.
# Usage:
#
#   EXISTS=$(tbl_exists mysql_user db tbl)
#
# :param LOC_USER: MySQL user on local machine
# :param DATABASE: local MySQL database holding table to manipulate
# :param TABLE_NAME: name of table whose existence to check


function tbl_exists() {

  if [[ $# != 3 ]]
  then
    echoerr "Not enough arguments to tbl_exists."
    exit 1
  fi

  LOC_USER=$1
  DB=$2
  TBL=$3

  read -r -d '' EXISTS_CMD <<EOF
       SELECT COUNT(*)
         FROM information_schema.tables 
        WHERE table_schema = '${DB}' 
          AND table_name = '${TBL}';
EOF

  HITS=$(mysql --login-path=${LOC_USER} ${DB} -sN -e "${EXISTS_CMD}" 2>/dev/null)

  if [[ $? != 0 ]]
  then
      # Try once more with -u and no pwd:
      HITS=$(mysql -u ${LOC_USER} ${DB} -sN -e "${EXISTS_CMD}")
      err_code=$?
      if [[ $err_code != 0 ]]
      then
          echoerr "MySQL error while checking existence of '${DB}.${TBL}'. Quitting."
          exit $err_code
      fi
  fi

  if [[ ${HITS} -gt 0 ]]
  then
     echo 1
  else
     echo 0
  fi
} # End function tbl_exists

#-----------------------
# new_tbl_name
#---------------

# Usage:
#
#   TBL_NAME=$(new_tbl_name myName myDb myTbl old)
#
# Given
#
#   $1: MySQL user for whom a login-path exists,
#   $2: a database name <database>,
#   $3: a table name,
#
# echoes a new table name with a number appended.
# It is guaranteed that table <database>.<table><n>
# does not exist. Examples, given table name:
#           
#    foo       returns foo1
#    foo_      returns foo_1
#    foo_old3  returns foo_old4, if no
#                foo_old<n> exists larger than n==4.
#
# :param LOC_USER: MySQL user on local machine
# :param DATABASE: local MySQL database holding table to manipulate
# :param TABLE_NAME: table name for which a new name is to be found.

function new_tbl_name() {

  if [[ -z $1 || -z $2 || -z $3 ]]
  then
    echoerr "Not enough args for function new_tbl_name."
    exit 1
  fi

  LOC_USER=$1
  DATABASE=$2
  TABLE_NAME=$3

  HIGHEST_N=$(next_suffix ${LOC_USER} ${DATABASE} ${TABLE_NAME})
  echo ${TABLE_NAME}${HIGHEST_N}

} # End function new_tbl_name

# ------------ Utility Functions For Tunneling to Remote MySQL Server ----------


#-----------------------
# rem_mysql_cmd
#---------------

# Executes a MySQL command on a remote machine,
# and returns the result
#
#  :param SSH_DEST: sshUser@remoteMachine
#  :param REM_MYSQL_USER: user on the remote MySQL server
#  :param REM_CMD: command to execute
#
# Prerequisites:
#  - remoteMachine must be accessible to sshUser
#  - REM_MYSQL_USER must have MySQL permissions at the remote server
#        either logging in via --login-path=${REM_MYSQL_USER}, or
#        via -u ${REM_MYSQL_USER}
#
# Usage: MY_RES=$(rem_mysql_cmd mySSHName thatMachine myMySqlName 'desc myDb.myTable')
#        echo $MY_RES


function rem_mysql_cmd() {

  if [[ $# < 3 ]]
  then
    echoerr "Not enough arguments to rem_mysql_cmd."
    exit 1
  fi

  SSH_DEST=$1
  REM_MYSQL_USER=$2
  REM_CMD=$3

  if [[ ! -z $4 ]]
  then
      MYSQL_CLI_OPTIONS=''
  else
      MYSQL_CLI_OPTIONS=$4
  fi

  RES=$(ssh ${SSH_DEST} "mysql --login-path=${REM_MYSQL_USER} \"${MYSQL_CLI_OPTIONS}\" -sN -e \"${REM_CMD}\"" 2>/dev/null)

  if [[ $? != 0 ]]
  then
      # Try once more with -u and no pwd:
      RES=$(ssh ${SSH_DEST} "mysql -u ${REM_MYSQL_USER} \"${MYSQL_CLI_OPTIONS}\" -sN -e \"${REM_CMD}\"")

      err_code=$?
      if [[ $err_code != 0 ]]
      then
          echoerr "MySQL error while remotely executing $REM_CMD. Quitting."
          exit $err_code
      fi
  fi

  echo $RES

} # End function rem_mysql_cmd

#-----------------------
# rem_db_exists
#---------------

# Echos '1' if given database exists on remote mysql server
# Else echos '0'.
# Usage:
#
#   EXISTS=$(rem_db_exists sshUser remoteMachnine rem_mysql_user rem_db)
#
#  :param SSH_DEST: sshUser@remoteMachine
#  :param REM_MYSQL_USER: user on the remote MySQL server
#  :param REM_DB: remote MySQL database name
#
# Prerequisites:
#  - remoteMachine must be accessible to sshUser
#  - REM_USER must have MySQL permissions at the remote server
#        either logging in via --login-path=${REM_USER}, or
#        via -u ${REM_USER}
#

function rem_db_exists() {

  if [[ $# != 3 ]]
  then
    echoerr "Not enough arguments to rem_db_exists."
    exit 1
  fi

  SSH_DEST=$1
  REM_MYSQL_USER=$2
  REM_DB=$3

  # Note: using information_schema to check
  # for number of tables in db to be > 0
  # won't work if the db to test is empty.
  # Must use SHOW DATABASES instead
  read -r -d '' EXISTS_CMD <<EOF
       SHOW DATABASES LIKE '${REM_DB}';
EOF

  HITS=$(rem_mysql_cmd $SSH_DEST $REM_MYSQL_USER "${EXISTS_CMD}")

  if [[ $? != 0 ]]
  then
     echoerr "MySQL error while checking existence of '${DB}'. Quitting."
     exit 1
  fi

  if [[ ${HITS} == ${REM_DB} ]]
  then
     echo 1
  else
     echo 0
  fi
} # End function rem_db_exists

#-----------------------
# rem_tbl_exists
#---------------

# Returns 1 if a given remote table exists on a remote
# machine. Else returns 0.
#
#  :param SSH_DEST: sshUser@remoteMachine
#  :param REM_MYSQL_USER: user on the remote MySQL server
#  :param REM_DB: remote MySQL database name
#  :param REM_TBL: remote MySQL database table
#
# Prerequisites:
#  - remoteMachine must be accessible to sshUser
#  - REM_USER must have MySQL permissions at the remote server
#        either logging in via --login-path=${REM_USER}, or
#        via -u ${REM_USER}
#
# Usage: MY_RES=$(rem_tbl_exits mySSHName thatMachine myMySqlName myDb myTable)
#        echo $MY_RES

function rem_tbl_exists() {

  if [[ $# != 4 ]]
  then
    echoerr "Not enough arguments to rem_tbl_exists."
    exit 1
  fi

  SSH_DEST=$1
  REM_MYSQL_USER=$2
  REM_DB=$3
  REM_TBL=$4

  read -r -d '' EXISTS_CMD <<EOF
       SELECT COUNT(*)
         FROM information_schema.tables 
        WHERE table_schema = '${REM_DB}' 
          AND table_name = '${REM_TBL}';
EOF

  HITS=$(ssh ${SSH_DEST} "mysql --login-path=\"${REM_MYSQL_USER}\" -sN -e \"${EXISTS_CMD}\"" 2>/dev/null)

  if [[ $? != 0 ]]
  then
      # Try once more with -u and no pwd:
      HITS=$(ssh ${SSH_DEST} "mysql -u \"${REM_MYSQL_USER}\" -sN -e \"${EXISTS_CMD}\"")
      err_code=$?
      if [[ $err_code != 0 ]]
      then
          echoerr "MySQL error while checking existence of '${DB}.${TBL}'. Quitting."
          exit $err_code
      fi
  fi

  if [[ ${HITS} -gt 0 ]]
  then
     echo 1
  else
     echo 0
  fi
} # End function rem_tbl_exists

#-----------------------
# rem_next_suffix
#---------------

function rem_next_suffix() {

# Finds the highest number at the end of a MySQL table
# names that is not yet taken. Used for finding table
# names to save tables into. Example: Given 'my_table_old',
# and a MySQL db, the function looks through that db
# for names of the form 'my_table_old1', 'my_table_old22',
# etc. and returns the next number guaranteed to make
# a table name unique. In this case: 23. The function does
# note fill 'holes': if my_table_old1 and my_table_old3
# exist, the function will return 4, not 2.
#
# I.e. given a database_name, and a table_name_root, which 
# may or may not end with a number, retun <n> such that 
# table_name_root<n> is unique in database_name.
# OK, a funky function.
#
#  Usage:
#    NEXT_NAME=$(rem_next_suffix mySSHName myMySQLName myDb myTable_old)

  # Check parameters:
  if [[ -z $1 || -z $2 || -z $3 || -z $4 ]]
  then
    echoerr "Not enough args for function rem_next_suffix: $USAGE"
    exit 1
  fi

  SSH_DEST=$1
  REM_MYSQL_USER=$2
  REM_DB=$3
  REM_TABLE_NAME_ROOT=$4

  MYSQL_CLI_OPTIONS="--skip-column-names --silent"

  # A query over the MySQL information schema table;
  # The '.*' matches any chars:

  read -rd '' PROBE_CMD <<EOF
  SELECT table_name 
    FROM information_schema.tables 
   WHERE table_schema = '${REM_DB}'
     AND table_name REGEXP '${REM_TABLE_NAME_ROOT}.*';
EOF

  TBLS=$(rem_mysql_cmd $SSH_DEST $REM_MYSQL_USER "${PROBE_CMD}" $MYSQL_CLI_OPTIONS)

  # Now might have $TBLS be: table_foo table_foo4 table_foo22
  # Goal: find the number 23

  MAX_NUM=0

  # Go through all returned tbl names, find
  # the ones that end with a number, and find
  # the highest number:

  for TBL in $TBLS
  do
      # The regex: 
      #            -n                : -n to suppress printing all patterns.
      #                                For macos must use -E instead of -R
      #            ${TABLE_NAME_ROOT}: move past the given root string
      #            \([0-9]*$\)       : find an arbitrary-length series 
      #                                of digits at the end of the name
      #                                (the '$' says end of line)
      # NOTE: The quotes MUST be double-quotes, else ${TABLE_NAME_ROOT}
      #       will not expand!

      TBL_NUM=$(echo $TBL | sed -n "s/${REM_TABLE_NAME_ROOT}\([0-9]*$\)/\1/p")
      if [[ ${TBL_NUM} != '' && ${TBL_NUM} -gt ${MAX_NUM} ]]
      then
          # Replace old max number with new one:
          MAX_NUM=${TBL_NUM}
      fi
  done
  # Return one higher than the max number:

  echo $((${MAX_NUM} + 1))
}

#-----------------------
# rem_new_tbl_name
#---------------

# Given a table name, return a new table name
# guaranteed not to exist on a remote server.
# The new table will be REM_TABLE_NAME_ROOT<n>
# where <n> is the highest number that will
# make the table name unique on the remote server.
# 'Holes' are not filled: if table_old1 and table_old4
# exist, then table_old5 is returned, not table_old2
#
#  :param SSH_DEST: sshUser@remoteMachine
#  :param REM_MYSQL_USER: user on the remote MySQL server
#  :param REM_DB: remote MySQL database name
#  :param REM_TABLE_NAME_ROOT: remote MySQL table to disambiguate
#
# Prerequisites:
#  - remoteMachine must be accessible to sshUser
#  - REM_USER must have MySQL permissions at the remote server
#        either logging in via --login-path=${REM_USER}, or
#        via -u ${REM_USER}
#
# Usage: MY_RES=$(rem_new_tbl_name mySSHName thatMachine myMySqlName myDb myTable_new)
#        echo $MY_RES
#

function rem_new_tbl_name() {

  if [[ -z $1 || -z $2 || -z $3 || -z $4 ]]
  then
    echoerr "Not enough args for function rem_new_tbl_name."
    exit 1
  fi
  
  SSH_DEST=$1
  REM_MYSQL_USER=$2
  REM_DB=$3
  REM_TABLE_NAME_ROOT=$4

  HIGHEST_N=$(rem_next_suffix $SSH_DEST $REM_MYSQL_USER $REM_DB $REM_TABLE_NAME_ROOT )

  echo ${REM_TABLE_NAME_ROOT}${HIGHEST_N}

} # End function rem_new_tbl_name
