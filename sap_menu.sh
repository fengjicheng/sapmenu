#!/usr/bin/env bash
# ***************************************************************
# *                                                             *
# *                           NOTICE                            *
# *                     SAP服务器自动启动交互脚本                *
# ***************************************************************
case `uname` in
  Linux)
    case `uname -m` in
      ia64)  
        _PLATFORM=linuxia64
        ;;
      x86_64)  
        _PLATFORM=linuxx86_64
        ;;
      s390x)  
        _PLATFORM=linuxs390x
        ;;
      ppc64)  
        _PLATFORM=linuxppc64
        ;;
      i686|i386)
        _PLATFORM=linuxintel
        ;;
      *)
        _PLATFORM=linuxintel
        ;;
    esac
    ;;

  AIX*)
    _PLATFORM=rs6000_64
    ;;

  Sun*)
    case `uname -m` in
      sun4u*)
        _PLATFORM=sun_64
        ;;
      i86pc)
        _PLATFORM=sunx86_64
        ;;
      *)
        _PLATFORM=sun_64
        ;;
    esac
    ;;

  HP*)
    case `uname -m` in
      ia64)
        _PLATFORM=hpia64
        ;;
      *)
        _PLATFORM=hp_64
        ;;
    esac
    ;;

  OSF*)
    _PLATFORM=alphaosf
    ;;

  OS/390*)
    _PLATFORM=os390
    ;;

  *)
    _PLATFORM=os390
    ;;

esac 
#虚拟化环境判断
VIRTUALIZATION=""
VIRTTYPE=""     # full/para
VIRTDOM=""      # Dom0, DomU
VIRTPRODUCT=""  # Oracle OVM,Red Hat RHEV,Huawei Fusionsphere, ...

# 1. determine virtualization technology
virt="`lscpu 2>/dev/null | grep -i 'Hypervisor vendor:' | awk '{print $3}'`"
case $virt in
   "VMware")
     VIRTUALIZATION=ESX
     VIRTPRODUCT=VMware
     ;;
   "KVM")
     VIRTUALIZATION=KVM
     #VIRTPRODUCT=KVM
     ;;
   "Xen")
     VIRTUALIZATION=Xen
     #VIRTPRODUCT=Xen
     ;;
   "Microsoft")
     VIRTUALIZATION=HyperV
     VIRTPRODUCT=Microsoft
     ;;
   "pHyp")
     VIRTUALIZATION=pHyp
     VIRTPRODUCT=IBM
     ;;
esac


######################################
# 启动前
######################################
######################################
# Verify User Environment
# 验证JAVA环境变量
######################################
function check_java {
if [[ $JAVA_HOME = "" ]]
then
   clear
   printf "The JAVA_HOME variable must be set when running this script to avoid start-up errors.\n"
   printf "Please rerun this script after setting JAVA_HOME and adding it to the PATH variable.\n"
   printf "Exiting...\n"
   sleep 2
   exit 1
fi
}
#检测当前用户
function check_user {
   if [ $(id -u) -ne 0 ]
   then
      clear
      printf "Please run this script as the root user.\n"
      printf "Exiting...\n"
      sleep 2
      exit 1
   fi
}
#判断实例状态
function sapinstance_status {
  local pid
  local pids

  [ ! -f "/usr/sap/$SID/$InstanceName/work/kill.sap" ] && return "NOT_RUNNING"
  pids=$(awk '$3 ~ "^[0-9]+$" { print $3 }' /usr/sap/$SID/$InstanceName/work/kill.sap)
  for pid in $pids
  do
    [ `pgrep -f -U $sidadm $InstanceName | grep -c $pid` -gt 0 ] && return "SUCCESS"
  done
  return "NOT_RUNNING"
}

function have_binary {
   if [ -x "$1" ]; then
      return 0  # 可执行文件存在
   else
      return 1  # 可执行文件不存在
   fi
}
declare -A profile_info
# 获得SAP 所有实例
function get_sap_list {
   clear
   printf "Loading...\n"
   PROFILES=$(ls -1 /usr/sap/???/SYS/profile/???_*_* | grep -vE '\.[0-9]|\.old|\_check|\.log\.back|\.backup|dev_' 2>/dev/null)
   index=1
   for PROFILE in $PROFILES; do
      # profile suddenly disappeared?
      if [ ! -e "$PROFILE" ]; then
         continue
      fi
      SID="`basename $PROFILE | cut -d_ -f1`"
      InstanceName="`basename $PROFILE  | cut -d_ -f2`"
      InstanceNr="`echo "$InstanceName" | sed 's/.*\([0-9][0-9]\)$/\1/'`"
      SAPVIRHOST="`basename $PROFILE  | cut -d_ -f3`"
      SIDADM="`echo $SID | tr '[:upper:]' '[:lower:]'`adm"
      DIR_PROFILE="/usr/sap/$SID/SYS/profile"
      #获得启动参数文件
      if [ ! -r "$DIR_PROFILE/START_${InstanceName}_${SAPVIRHOST}" -a -r "$DIR_PROFILE/${SID}_${InstanceName}_${SAPVIRHOST}" ]; then
         SAPSTARTPROFILE="$DIR_PROFILE/${SID}_${InstanceName}_${SAPVIRHOST}"
      else
         SAPSTARTPROFILE="$DIR_PROFILE/START_${InstanceName}_${SAPVIRHOST}"
      fi
      #sapstartsrv状态获取
      if pgrep -f -l "sapstartsrv .*pf=.*${SID}_${InstanceName}_${SAPVIRHOST}" >/dev/null
      then
         SAPSTARTSRV_STATUS="SUCCESS"
      elif pgrep -f -l "sapstart .*pf=.*${SID}_${InstanceName}_${SAPVIRHOST}" >/dev/null
      then
         SAPSTARTSRV_STATUS="SUCCESS"
      else
         SAPSTARTSRV_STATUS="NOT_RUNNING"
      fi
      #获取可执行程序路径
      if have_binary /usr/sap/$SID/$InstanceName/exe/sapstartsrv && have_binary /usr/sap/$SID/$InstanceName/exe/sapcontrol
      then
         DIR_EXECUTABLE="/usr/sap/$SID/$InstanceName/exe"
         SAPSTARTSRV="/usr/sap/$SID/$InstanceName/exe/sapstartsrv"
         SAPCONTROL="/usr/sap/$SID/$InstanceName/exe/sapcontrol"
         
      elif have_binary /usr/sap/$SID/SYS/exe/run/sapstartsrv && have_binary /usr/sap/$SID/SYS/exe/run/sapcontrol
      then
         DIR_EXECUTABLE="/usr/sap/$SID/SYS/exe/run"
         SAPSTARTSRV="/usr/sap/$SID/SYS/exe/run/sapstartsrv"
         SAPCONTROL="/usr/sap/$SID/SYS/exe/run/sapcontrol"
      fi
      # 获得系统类型
      output=`su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function ParameterValue system/type -format script | grep '^0 : ' | cut -d' ' -f3"`
      if [ $? -eq 0 ]
      then
         SYSTEM_TYPE="${output}"
         #判断实例名
         if [ "$(echo "$InstanceName" | cut -c1-3)" = "HDB" ]; then
            SYSTEM_TYPE="HDB"
         fi
      else
         SYSTEM_TYPE="unknown"
      fi
      # 判断是否为hana
      if [ "$SYSTEM_TYPE" = "HDB" ]; then
         SAPWORK="/usr/sap/$SID/$InstanceName/$SAPVIRHOST/trace"
         # 如果为HANA 则 启动参数也要改写
         SAPSTARTPROFILE="/usr/sap/$SID/SYS/global/hdb/custom/config/"
      else
         # 如果SYSTEM_TYPE不为HDB，执行第二行代码
         SAPWORK="/usr/sap/$SID/$InstanceName/work"
      fi
      local rc='UNKNOWN'
      if [ $SAPSTARTSRV_STATUS="SUCCESS" ]
      then
         local count=0
         local MONITOR_SERVICES_default="disp+work|TREXDaemon.x|msg_server|enserver|enrepserver|jcontrol|jstart|enq_server|enq_replicator|hdbindexserver|hdbnameserver|hdbdaemon"
         local SERVNO
         local output
         output=`su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function GetProcessList -format script"`
         # we have to parse the output, because the returncode doesn't tell anything about the instance status
         for SERVNO in `echo "$output" | grep '^[0-9] ' | cut -d' ' -f1 | sort -u`
         do
            local COLOR=`echo "$output" | grep "^$SERVNO dispstatus: " | cut -d' ' -f3`
            local SERVICE=`echo "$output" | grep "^$SERVNO name: " | cut -d' ' -f3`
            local STATE="UNKNOWN"
            local SEARCH
            case $COLOR in
            GREEN)       STATE="SUCCESS";;
            YELLOW)      STATE="WARN";;
            *)                  STATE="NOT_RUNNING";;
            esac
            SEARCH=`echo "$MONITOR_SERVICES_default" | sed 's/\+/\\\+/g' | sed 's/\./\\\./g'`
            if [ `echo "$SERVICE" | egrep -c "$SEARCH"` -eq 1 ]
            then
               if [ $STATE="NOT_RUNNING" ]
               then
                  rc=$STATE
               fi
               count=1
            fi
         done
         if [ $count -eq 0 ]; then
            rc="ERR_GENERIC"
         fi
      fi
      profile_info["$index,SID"]=$SID
      profile_info["$index,InstanceName"]=$InstanceName
      profile_info["$index,InstanceNr"]=$InstanceNr
      profile_info["$index,SAPVIRHOST"]=$SAPVIRHOST
      profile_info["$index,SIDADM"]=$SIDADM
      profile_info["$index,DIR_PROFILE"]=$DIR_PROFILE
      profile_info["$index,SAPSTARTPROFILE"]=$SAPSTARTPROFILE
      profile_info["$index,SAPSTARTSRV_STATUS"]=$SAPSTARTSRV_STATUS
      profile_info["$index,DIR_EXECUTABLE"]=$DIR_EXECUTABLE
      profile_info["$index,SAPSTARTSRV"]=$SAPSTARTSRV
      profile_info["$index,SAPCONTROL"]=$SAPCONTROL
      profile_info["$index,STATUS"]=$rc
      profile_info["$index,SAPWORK"]=$SAPWORK
      profile_info["$index,SYSTEM_TYPE"]=$SYSTEM_TYPE
      ((index++))
   done
}
#判断是否为SAP环境
function check_sap_env {
   clear
   printf "Loading...\n"
   if [ ! -f "/usr/sap/sapservices" ]
   then
      clear
      printf "请确定您是否已经安装了SAP系统\n"
      printf "Exiting...\n"
      sleep 2
      exit 1
   fi
   
}
# 启动SAP服务
function sapinstance_start {
   local rc=1
   local output=""
   local loopcount=0
   while [ $loopcount -lt 2 ]
   do
      loopcount=$(($loopcount + 1))

      check_sapstartsrv
      rc=$?
      if [ $rc="SUCCESS" ]; then
         output=`su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function Start"`
         rc=$?
         # 日志记录
         log_action "Starting SAP Instance $SID-$InstanceName: $output"
      fi

      if [ $rc -ne 0 ]
      then
         # 日志记录
         log_action "SAP Instance $SID-$InstanceName start failed."
         return "ERR_GENERIC"
      fi

      local startrc=1
      while [ $startrc -gt 0 ]
      do
         local waittime_start=`date +%s`
         output=`su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function  WaitforStarted 30 10"`
         startrc=$?
         local waittime_stop=`date +%s`

         if [ $startrc -ne 0 ]
         then
         if [ $(($waittime_stop - $waittime_start)) -ge 30 ]
         then
            sapinstance_monitor NOLOG
            if [ $? -eq "SUCCESS" ]
            then
               output="START_WAITTIME (30) has elapsed, but instance monitor returned SUCCESS. Instance considered running."
               startrc=0; loopcount=2
            fi
         else
            if [ $loopcount -eq 1 ] 
            then
               log_action "SAP Instance $SID-$InstanceName start failed: $output"
               log_action "Try to recover $SID-$InstanceName"
               # 强制清理实例
               cleanup_instance
            else
               loopcount=2
            fi
            startrc=-1
         fi
         else
         loopcount=2
         fi
      done
   done

   if [ $startrc -eq 0 ]
   then
      log_action "SAP Instance $SID-$InstanceName started: $output"
      # 启动成功
      rc=0
   else
      # 日志记录
      log_action "SAP Instance $SID-$InstanceName start failed: $output"
      # 启动失败
      rc=1
   fi
   return "$rc"
}
SYSTEMCTL="systemctl"
# 检查systemd服务
function check_systemd_integration {
    local systemd_unit_name="SAP${SID}_${InstanceNr}"
    local rc=1

    if which "$SYSTEMCTL" 1>/dev/null 2>/dev/null; then
        if $SYSTEMCTL list-unit-files | \
            awk '$1 == service { found=1 } END { if (! found) {exit 1}}' service="${systemd_unit_name}.service";
         then
            rc=0
        else
            rc=1
        fi
    fi
    return "$rc"
}

function check_sapstartsrv {
   local restart=0
   local runninginst=""
   local chkrc=0
   local output=""

   # check for sapstartsrv/systemd integration
   #  检查systemd
   if check_systemd_integration; then
      # 拼接systemd名字
      local systemd_unit_name="SAP${SID}_${InstanceNr}"
      # 检查systemd 服务
      if "$SYSTEMCTL" is-active --quiet "$systemd_unit_name"; then
         log_action "ACT:systemd service $systemd_unit_name is active"
      else
         log_action "ACT:systemd service $systemd_unit_name is not active, it will be started using systemd"
         "$SYSTEMCTL" start "$systemd_unit_name" >/dev/null 2>&1; src=$?
         if [[ "$src" != 0 ]]; then
               log_action "ACT: error during start of systemd unit ${systemd_unit_name}!"
               return 1
         fi
         # use start, because restart does also stop sap instance
      fi
      return 0
   else # otherwise continue with old code...  否则使用旧代码
      #判断.sapstream5${InstanceNr}13是否存在，不存在则重启
      if [ ! -S /tmp/.sapstream5${InstanceNr}13 ]; then
         log_action "sapstartsrv is not running for instance $SID-$InstanceName (no UDS), it will be started now"
         restart=1
      else
         output=`su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr}  -function ParameterValue INSTANCE_NAME -format script"`
         if [ $? -eq 0 ]
         then
            runninginst=`echo "$output" | grep '^0 : ' | cut -d' ' -f3`
            if [ "$runninginst" != "$InstanceName" ]
            then
               log_action "sapstartsrv is running for instance $runninginst, that service will be killed"
               restart=1
            else
               output=`su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr}  -function AccessCheck Start"`
               if [ $? -ne 0 ]; then
                  log_action "FAILED : sapcontrol -nr $InstanceNr -function AccessCheck Start (`ls -ld1 /tmp/.sapstream5${InstanceNr}13`)"
                  log_action "sapstartsrv will be restarted to try to solve this situation, otherwise please check sapstsartsrv setup (SAP Note 927637)"
                  restart=1
               fi
            fi
         else
            log_action "sapstartsrv is not running for instance $SID-$InstanceName, it will be started now"
            restart=1
         fi
      fi

      if [ -z "$runninginst" ]; then runninginst=$InstanceName; fi
      #判断sapstartsrv 是否重启
      if [ $restart -eq 1 ]
      then
         pkill -9 -f "sapstartsrv.*$runninginst"

         # removing the unix domain socket files as they might have wrong permissions
         # or ownership - they will be recreated by sapstartsrv during next start
         rm -f /tmp/.sapstream5${InstanceNr}13
         rm -f /tmp/.sapstream5${InstanceNr}14

         $SAPSTARTSRV pf=$SAPSTARTPROFILE -D -u $sidadm

         # now make sure the daemon has been started and is able to respond
         local srvrc=1
         while [ $srvrc -eq 1 -a `pgrep -f "sapstartsrv.*$runninginst" | wc -l` -gt 0 ]
         do
            sleep 1
            su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function GetProcessList  > /dev/null 2>&1"
            srvrc=$?
         done

         if [ $srvrc -ne 1 ]
         then
            log_action "sapstartsrv for instance $SID-$InstanceName was restarted !"
            # 启动成功
            chkrc=0
         else
            log_action "sapstartsrv for instance $SID-$InstanceName could not be started!"
            #启动失败
            chkrc=1
         fi
      fi
      return "$chkrc"
   fi
}
#停止实例
function sapinstance_stop {
   local output=""
   local rc

   #检查sapstartsrv进程状态
   check_sapstartsrv
   rc=$?
   #如果sapstartsrv进程正常则调用Stop停止
   if [ $rc -eq 0 ]; then
      output=`su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr}  -function Stop"`
      rc=$?
      log_action "Stopping SAP Instance $SID-$InstanceName: $output"
   fi
   #如果sapstartsrv进程不正常则 WaitforStopped 3600 1
   if [ $rc -eq 0 ]
   then
      output=`su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr}  -function  WaitforStopped 3600 1"`
      if [ $? -eq 0 ]
      then
         log_action "SAP Instance $SID-$InstanceName stopped: $output"
         #启动成功
         rc=0
      else
         log_action "SAP Instance $SID-$InstanceName stop failed: $output"
         #启动失败
         rc=1
      fi
   else
      log_action "SAP Instance $SID-$InstanceName stop failed: $output"
      #启动失败
      rc=1
   fi
   return "$rc"
}

# 强行清理实例
function cleanup_instance {
   pkill -9 -f -U $SIDADM $InstanceName
   #使用 pkill -9 -f -U $sidadm $InstanceName 终止进程
   # 日志记录
   log_action "Terminated instance using 'pkill -9 -f -U $SIDADM $InstanceName'"

   # it is necessary to call cleanipc as user sidadm if the system has 'vmcj/enable = ON' set - otherwise SHM-segments in /dev/shm/SAP_ES2* cannot be removed
   su - $SIDADM -c "cleanipc $InstanceNr remove"
   # 日志记录
   log_action "Tried to remove shared memory resources using 'cleanipc $InstanceNr remove' as user $SIDADM"
   su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function StartService ${SID}  > /dev/null"
   return 0
}
#######################################
# Menu Actions
# 菜单动作
#######################################
function run_action {
   case $1 in
      h) clear;
         showhelp 
         printf "Press [enter] key to continue\n";
         read enterkey;
         ;;
      e) clear;
         printf "Exiting...\n";
         exit 1
         ;;
      r) clear;
         get_sap_list
         main_menu
         ;;
      #版本号
      v) clear;
         showversion 
         printf "Press [enter] key to continue\n";
         read enterkey;
         main_menu
         ;;
   *) clear;
         # 选中的行项目 
         if [ $1 -lt $index ]; then
            SID=${profile_info["$1,SID"]}
            InstanceName=${profile_info["$1,InstanceName"]}
            InstanceNr=${profile_info["$1,InstanceNr"]}
            SAPVIRHOST=${profile_info["$1,SAPVIRHOST"]}
            SIDADM=${profile_info["$1,SIDADM"]}
            DIR_PROFILE=${profile_info["$1,DIR_PROFILE"]}
            SAPSTARTPROFILE=${profile_info["$1,SAPSTARTPROFILE"]}
            SAPSTARTSRV_STATUS=${profile_info["$1,SAPSTARTSRV_STATUS"]}
            DIR_EXECUTABLE=${profile_info["$1,DIR_EXECUTABLE"]}
            SAPSTARTSRV=${profile_info["$1,SAPSTARTSRV"]}
            SAPCONTROL=${profile_info["$1,SAPCONTROL"]}
            STATUS=${profile_info["$1,STATUS"]}
            SAPWORK=${profile_info["$1,SAPWORK"]}
            SYSTEM_TYPE=${profile_info["$1,SYSTEM_TYPE"]}
            # 子界面可获得如上信息
            sub_menu
         else
            printf "Invalid option.\n";
            sleep 2;
            printf "Press [enter] key to continue\n";
            read enterkey;
            main_menu;
         fi
         ;;
   esac
}
#######################################
# Component Sub Menu Actions
#######################################
function run_sub_action {
case $1 in
  e) clear;
      printf "Exiting...\n";
      exit 1
      ;;
  m) clear;
      get_sap_list
      main_menu;
      ;;
  1) clear;
      printf "正在启动系统实例....";
      sapinstance_start
      rc=$?
      if [ $rc ]; then
         clear;
         printf "系统已完成启动\n";
         STATUS="SUCCESS"
      else
         clear;
         printf "系统启动失败\n";
         STATUS="NOT_RUNNING"
      fi
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   2) clear;
      printf "正在停止系统实例....";
      sapinstance_stop
      rc=$?
      if [ $rc ]; then
         clear;
         printf "系统停止已完成！五秒后将自动重启本实例！\n";
         STATUS="NOT_RUNNING"
         sleep 5;
         clear;
         printf "正在启动系统实例....";
         sapinstance_start
         rc=$?
         if [ $rc ]; then
            clear;
            printf "系统已完成启动\n";
            STATUS="SUCCESS"
         else
            clear;
            printf "系统启动失败\n";
            STATUS="NOT_RUNNING"
         fi
      else
         clear;
         printf "系统停止失败\n";
         STATUS="SUCCESS"
      fi
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   3) clear;
      printf "正在停止系统实例....";
      sapinstance_stop
      rc=$?
      if [ $rc ]; then
         clear;
         printf "系统停止已完成\n";
         STATUS="NOT_RUNNING"
      else
         clear;
         printf "系统停止失败\n";
         STATUS="SUCCESS"
      fi
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 获得所有进程
   4) clear;
      printf "\n"
      printf "您的实例${SID}(${InstanceNr}) 系统进程状态如下\n"  
      su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function GetProcessList"
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 启动startsrv服务
   5) clear;
      printf "\n"
      printf "您的实例${SID}(${InstanceNr})正在启动SAPSTARTSRV状态如下:\n"  
      su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function StartService ${SID}"
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 重启startsrv服务
   6) clear;
      printf "\n"
      printf "您的实例${SID}(${InstanceNr})正在重启SAPSTARTSRV状态如下:\n"  
      su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function RestartService"
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 获得所有进程
   7) clear;
      if [ $STATUS="SUCCESS" ]; then
         printf "您的实例${SID}(${InstanceNr})正在运行中，正在运行的实例禁止清理共享内存\n"  
      else
         printf "\n"
         printf "正在为您清理${SID}(${InstanceNr})本实例下共享内存\n"  
         su - ${SIDADM} -c "cleanipc $InstanceNr remove"
         printf "\n"
      fi
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 获得授权信息
   8) clear;
      printf "\n"
      printf "您的实例${SID}(${InstanceNr}) 授权信息如下\n"  
      su - ${SIDADM} -c "saplikey pf=${SAPSTARTPROFILE} -show"
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 强制终止实例
   9) clear;
      printf "\n"
      printf "您的实例${SID}(${InstanceNr}) 正在强制终止进程\n"
      cleanup_instance
      STATUS="NOT_RUNNING"
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 检查参数文件
   10) clear;
      printf "\n"
      printf "您的实例${SID}(${InstanceNr}) 参数文件检查如下\n"  
      su - ${SIDADM} -c "sappfpar check pf=${SAPSTARTPROFILE}"
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 检查java数据库连接
   95) clear;
      printf "\n"
      printf "正在为您检测实例${SID}(${InstanceNr}) 连接状态\n"   
      printf "正在获得..\n"
      cd  /usr/sap/${SID}/${InstanceName}/j2ee/configtool > /dev/null
      output=$(source /usr/sap/${SID}/${InstanceName}/j2ee/configtool/consoleconfig.sh << EOF
12
EOF
)
      clear
      printf "\n"
      printf "您的J2EE实例${SID}(${InstanceNr}) 连接状态为:\n" 
      printf "$(echo "$output" | grep "Connecting to database")\n"
      printf "$(echo "$output" | grep "Scanning cluster data")\n"
      cd  /usr/sap/ > /dev/null
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 检查ABAP系统数据库连接
   96) clear;
      printf "\n"
      printf "正在为您检查数据库连接,显示00证明连接正常\n"  
      su - ${SIDADM} -c "R3trans -dx -w ${SAPWORK}/trans.log"
      printf "若失败请检查${SAPWORK}/trans.log日志\n"  
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 启动Configtool
   97) clear;
      printf "\n"
      printf "正在为您启动Configtool.您的必须使用XHELL等工具\n"  
      cd  /usr/sap/${SID}/${InstanceName}/j2ee/configtool > /dev/null
      source /usr/sap/${SID}/${InstanceName}/j2ee/configtool/configtool.sh
      cd  /usr/sap/ > /dev/null
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   # 获得hana版本
   98) clear;
      printf "\n"
      printf "您的数据库实例${SID}(${InstanceNr}) 版本为\n"  
      su - ${SIDADM} -c "hdbsrvutil -v "
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
   #获得Log
   99) clear;
      printf "\n"
      printf "您的实例${SID}(${InstanceNr}) 可收集的日志列表为\n"
      printf "|================================log list======================================\n"
      su - ${SIDADM} -c "sapcontrol -nr ${InstanceNr} -function ListLogFiles -format script" | awk  -v sid="${SID}" -v instance="${InstanceName}"  'BEGIN{FS=": "} /filename:/{filename=$2} /size:/{size=$2; printf "| filename :/usr/sap/%s/%s/%s  size: %s\n", sid, instance, filename, size}'
      printf "|==============================================================================\n"   
      printf "\n"
      sleep 2;
      printf "Press [enter] key to continue\n";
      read enterkey;
      sub_menu
      ;;
  *) clear;
     printf "Invalid option.\n";
     sleep 2;
     printf "Press [enter] key to continue\n";
     read enterkey;
     sub_menu
     ;;
esac
}
##################################################
# Logging functions
##################################################
function log_action {
   echo "`date '+%Y-%m-%d %T'`">>/usr/sap/sap_action.log
   echo "  $1     ">>/usr/sap/sap_action.log
   echo "-----------------------------------------------------">>/usr/sap/sap_action.log
}
function showversion {
   printf "|================================Version Infor=================================\n"
   printf "|                                                                              \n"
   printf "| V 0.0.1 : 初始化版本                                                          \n"
   printf "|                                                                              \n"
   printf "|==============================================================================\n"
}

##################################################
# Help functions
##################################################
function showhelp {
   printf "|====================================帮助文档===================================\n"
   printf "|                                                                              \n"
   printf "| 此工具为SHELL 调用sapcontrol来启动停止SAP服务，如在启停中遇到问题请检查相应日     \n"
   printf "| 志文件，或者联系作者： 冯际成  手机号 15209793953 Email： 604756218@qq.com      \n"
   printf "|                                                                              \n"
   printf "| 也可使用sap提供工具自动化分析相关日志文件                                       \n"
   printf "| https://supportportal-pslogassistant-app.cfapps.eu10.hana.ondemand.com/      \n"
   printf "|                                                                              \n"
   printf "| 本程序日志文件为:/usr/sap/sap_action.log                                      \n"
   printf "|                                                                              \n"
   printf "|==============================================================================\n"
}
###################################################
# Sub Menu for components
###################################################
function sub_menu {
   clear
   useropt=0
   while [ $useropt != e ]
   do
      clear
      printf "|===================SAP Instance Options Menu=======================================\n"
      printf "| Welcome to the world of SAP, welcome to use this script                           \n"
      printf "| This system is for personal communication and learning purposes only.             \n"
      printf "| Please do not use it for any other purposes!                                      \n"
      printf "|=====================System Instance Infor=========================================\n"
      printf "| %-15s%-10s %-22s%-10s %-16s%-15s\n" "System ID:" ${SID} "Instance Number:" ${InstanceNr}  "Service Account:" ${SIDADM}
      printf "| %-15s%-10s %-22s%-10s %-16s%-15s\n" "Instance Name:" ${InstanceName} "Start Service Status:" ${SAPSTARTSRV_STATUS} "Status:" ${STATUS} 
      printf "| %-15s%-40s\n" "Work Log:" ${SAPWORK} 
      printf "| %-15s%-40s\n" "Startup Profile:" ${SAPSTARTPROFILE} 
      if [ "$STATUS" = "SUCCESS" ]; then

         printf "| %-15s%-40s\n" "Startup Time:" ${SAPSTARTPROFILE} 
      fi
      printf "|===================================================================================\n"
      printf "| 1.  Start                                                                         \n"
      printf "| 2.  Restart                                                                       \n"
      printf "| 3.  Shutdown                                                                      \n"
      printf "| 4.  GetProcessList                                                                \n"
      printf "| 5.  StartService                                                                  \n"
      printf "| 6.  RestartService                                                                \n"
      if [ "$SYSTEM_TYPE" = "ABAP" ]; then
         printf "| 7.  Cleanipc                                                                   \n"
         printf "| 8.  Get License                                                                \n"
         printf "| 9.  Force Kill                                                                 \n"
         printf "| 10. Check Start Profile                                                        \n"
         #判断是否为消息服务
         if [ "$(echo "$InstanceName" | cut -c1)" = "D" ]; then
            printf "| 96. Check Database Connection                                                  \n"
         fi
      fi
      if [ "$SYSTEM_TYPE" = "J2EE" ]; then
         printf "| 7.  Cleanipc                                                                   \n"
         printf "| 9.  Force Kill                                                                 \n"
         printf "| 10. Check Start Profile                                                        \n"
      fi
      #判断是否为JAVA实例
      if [ "$(echo "$InstanceName" | cut -c1)" = "J" ]; then
         printf "| 95. Check Database Connection                                                  \n"
         printf "| 97. Run Configtool                                                             \n"
      fi
      if [ "$SYSTEM_TYPE" = "SMDA" ]; then
         printf "| 7.  Cleanipc                                                                   \n"
         printf "| 9.  Force Kill                                                                 \n"
         printf "| 10. Check Start Profile                                                        \n"
      fi
      if [ "$SYSTEM_TYPE" = "HDB" ]; then
         printf "| 98. Get HDB Version                                                            \n"
      fi
      printf "| 99. Collect logs                                                                  \n"
      printf "| e.  Exit                                                                          \n"
      printf "| m.  Return to Main Menu                                                           \n"
      printf "|===================================================================================\n"
   
   printf "Please enter your selection and press <Enter>\n" 
   read useropt
   run_sub_action $useropt
   done
}

###################################################
# Main Menu
###################################################
function main_menu {
   clear
   userchoice=0
   while [ $userchoice != e ]
   do
      clear
      printf "|======SAP Maintenance Menu=========================================================\n"
      printf "| Welcome to the world of SAP, welcome to use this script                           \n"
      printf "| This system is for personal communication and learning purposes only.             \n"
      printf "| Please do not use it for any other purposes!                                      \n"
      printf "| h.  Help                                                                          \n"
      printf "| r.  Refresh                                                                       \n"
      printf "| v.  Version                                                                       \n"
      printf "| e.  Exit                                                                          \n"
      printf "| --------------------SAP Components------------------------------------------------\n"
      printf "|     %-5s %-12s %-10s %-6s %-15s %-12s %-8s\n" "SID" "InstanceName" "InstanceNr" "Type" "SAPVIRHOST"  "SAPSTARTSRV" "Status"
      for ((i = 1; i < index; i++)); do
         printf "| %-2s. %-5s %-12s %-10s %-6s %-15s %-12s %-8s\n" $i "${profile_info["$i,SID"]}" "${profile_info["$i,InstanceName"]}" "${profile_info["$i,InstanceNr"]}" "${profile_info["$i,SYSTEM_TYPE"]}" "${profile_info["$i,SAPVIRHOST"]}" "${profile_info["$i,SAPSTARTSRV_STATUS"]}" "${profile_info["$i,STATUS"]}"
      done
      printf "|===================================================================================\n"
      printf "Please enter your selection and press <Enter>\n" 
      read userchoice
      run_action $userchoice
   done
}

############################
# Main Program Starts Here
############################
################################################################################################
# Added the following for the new Administration Console script name
export HOSTNAME=`hostname`
STATUPTIME=$(date -d "$(awk -F. '{print $1}' /proc/uptime) second ago" +"%Y-%m-%d %H:%M:%S")
SAPHOSTCTRL="/usr/sap/hostctrl/exe/saphostctrl"
SAPHOSTEXEC="/usr/sap/hostctrl/exe/saphostexec"
SAPHOSTSRV="/usr/sap/hostctrl/exe/sapstartsrv"
SAPHOSTOSCOL="/usr/sap/hostctrl/exe/saposcol"
################################################################################################
# 取消java检测
#check_java
check_user
check_sap_env
get_sap_list
main_menu
