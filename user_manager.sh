#!/bin/sh

htdocs_chroot_path="/var/www/htdocs"
log_path="/var/log/user_manager.log"
lock_list="baytuch,mailman,vasya"

user_exists="NO"
group_exists="NO"
target_user_id=""
target_group_id=""
error_trig="NO"


check_exists() {
  user_exists=NO
  group_exists=NO
  if [ ! -z "$(grep "^$1:.*$" /etc/passwd)" ]; then
    user_exists="YES"
  fi
  if [ ! -z "$(grep "^$1:.*$" /etc/group)" ]; then
    group_exists="YES"
  fi
}

create_user() {
  groupadd -ov -g $3 $1
  useradd -v -m -d /home/$1 -g $3 -s /bin/ksh -u $2 $1
  passwd $1
}

delete_user() {
  userdel -rv $1
  groupdel -v $1
}

logger() {
  if [ ! -f $log_path ]; then
    touch $log_path
  fi
  mess=[$(date '+%Y-%m-%d %H:%M:%S')]" "$1
  echo $mess >> $log_path
  echo $mess
}

get_target_ids() {
  if [ $user_exists == "YES" ]; then
    target_user_id=$(grep "^$1" /etc/passwd | sed -r -e 's|^.*:([0-9]+):[0-9]+:.*$|\1|g')
    target_group_id=$(grep "^$1" /etc/passwd | sed -r -e 's|^.*:[0-9]+:([0-9]+):.*$|\1|g')
  else
    users_ids=$(cat /etc/passwd | sed -r -e 's|^.*:([0-9]+:[0-9]+):.*$|\1|g')
    tmp_last_user_id=0
    for line in $users_ids; do
      tmp_user_id=${line%:*}
      tmp_group_id=${line#*:}
      if [ ${#tmp_user_id} -eq 4 ] && [ ${#tmp_group_id} -eq 4 ]; then
        if [ $tmp_user_id -eq $tmp_group_id ]; then
          if [ $tmp_user_id -gt $tmp_last_user_id ]; then
            tmp_last_user_id=$tmp_user_id
          fi
        fi
      fi
    done
    target_user_id=$tmp_last_user_id
    target_group_id=$tmp_last_user_id
  fi
  target_user_id=$(echo $target_user_id | sed 's/[^0-9]//g')
  target_group_id=$(echo $target_group_id | sed 's/[^0-9]//g')
  if [ $user_exists == "NO" ] && [ ! -z $target_user_id ] && [ ! -z $target_group_id ]; then
    target_user_id=$((target_user_id + 1))
    target_group_id=$((target_group_id + 1))
  fi
}

user_tree_config() {
  if [ -d /home/$1 ]; then
    chmod 700 /home/$1
    chmod 700 /home/$1/.ssh
    chmod 600 /home/$1/{.Xdefaults,.cshrc,.cvsrc,.login,.mailrc,.profile}
    logger "TREE CONFIG: was configured home dir"
    if [ -d $htdocs_chroot_path ]; then
      mkdir $htdocs_chroot_path/$1
      chown $1:$1 $htdocs_chroot_path/$1
      ln -s $htdocs_chroot_path/$1 /home/$1/htdocs
      chown $1:$1 /home/$1/htdocs
      logger "TREE CONFIG: was configured htdocs dir"
    else
      logger "TREE CONFIG: htdocs chroot not found!"
    fi
  else
    logger "TREE CONFIG: home folder not found!"
  fi
}

user_tree_delete() {
  if [ -d /home/$1 ]; then
    if [ -d /home/$1/htdocs ]; then
      rm -rf /home/$1/htdocs
    fi
    if [ -d $htdocs_chroot_path/$1 ]; then
      rm -rf $htdocs_chroot_path/$1
    fi
    if [ ! -d /home/$1/htdocs ] && [ ! -d $htdocs_chroot_path/$1 ]; then
      logger "TREE DELETE: was deteled htdocs dir"
    else
      error_trig="YES"
      logger "TREE DELETE: failed to delete folder tree!"
    fi
  else
    error_trig="YES"
    logger "TREE DELETE: home folder not found!"
  fi
}

do_create_user() {
  logger "WORKER: create a new user..."
  if [ -z $1 ]; then
    logger "WORKER: you must provide username!"
  else
    check_exists $1
    if [ $user_exists == "YES" ]; then
      logger "WORKER: user $1 already exists"
    else
      get_target_ids $1
      if [ ${#target_user_id} -eq 4 ] && [ ${#target_group_id} -eq 4 ]; then
        logger "WORKER: process of creating a new user has started"
        logger "WORKER: -> login - $1"
        logger "WORKER: -> user_id - $target_user_id"
        logger "WORKER: -> group_id - $target_group_id"
        create_user $1 $target_user_id $target_group_id
        check_exists $1
        if [ $user_exists == "YES" ]; then
          logger "WORKER: user created successfully"
          logger "WORKER: user folder tree configuration..."
          user_tree_config $1
        else
          logger "WORKER: user creation failure!"
        fi
      else
        logger "WORKER: error generating identifiers!"
      fi
    fi
  fi
}

do_delete_user() {
  logger "WORKER: removing a user account..."
  if [ -z $1 ]; then
    logger "WORKER: you must provide username!"
  else
    check_exists $1
    if [ $user_exists == "NO" ]; then
      logger "WORKER: user $1 not found!"
    else
      get_target_ids $1
      if [ ${#target_user_id} -ne 4 ]; then
        logger "WORKER: you cannot delete the service user!"
      else
        deny_del="NO"
        for tmp_user_name in $(echo $lock_list | tr "," "\n"); do
          if [ $1 == $tmp_user_name ]; then
            deny_del="YES"
            break
          fi
        done
        if [ $deny_del == "NO" ]; then
          logger "WORKER: deleting a user's folder tree..."
          user_tree_delete $1
          if [ $error_trig == "NO" ]; then
            logger "WORKER: deleting a user account..."
            delete_user $1
            check_exists $1
            if [ $user_exists == "NO" ]; then
              logger "WORKER: user account of $1 deleted"
            else
              logger "WORKER: failed to delete account!"
            fi
          fi
        else
          logger "WORKER: the deletion of this user is blocked!"
        fi
      fi
    fi
  fi
}

if [ $(whoami) == "root" ]; then
  case "$1" in
    create)
    do_create_user $2
    ;;
    delete)
    do_delete_user $2
    ;;
    *)
    logger "SELECTOR: unknown command"
    ;;
  esac
  exit 0
else
  echo "must be run as root!"
  exit 1
fi
