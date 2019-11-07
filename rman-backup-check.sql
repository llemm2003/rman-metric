set serveroutput on
/* Script for updated rman monitoring. This script will output "No Backup FAILURE" once the script sees the backups are within threshold limit
Threshold:
Level 0 - 7 Days + Grace period
Level 1 - 1 Day + Grace period
Archivelog - 8 hours
Grace-period - 12 hours
No Backup Failure will also happen if the database is second node, No archived log, Dataguard or on a windows.
*/
/* Variable declarations */
declare
/* Variables for threshold */
g_period integer := 12; -- Grace period (12 hours)
L1_threshold integer := 24; -- Level 1 threshold 1 day(23 hrs)
L0_threshold integer := 168; -- Level 0 threshold 7 days (168 days)
/* Variables for main operation */
db_role varchar2(20);
db_rolec integer := 0;
db_inst integer;
db_instc integer := 0;
backup_type varchar2(20);
backup_type_status varchar2(20);
backup_type_date varchar2(40);
L0 integer;
L1 integer;
L00 varchar2(50);
L11 varchar2(50);
/* The variable will hold data if there L0 backup that is less than a day old. Lack of L1 backup is superseded by L0 backup that is less than 1 day old. */
L001 varchar2(50);
/* *_stmt variable are for dynamic sql storage, this is required since the rman view does not work on Node B standby */
L00_stmt varchar2(500);
L11_stmt varchar2(500);
L001_stmt varchar2(500);
ARC_BACKUP integer;
OUTPUT_MESSAGE varchar2(30);
OS_string VARCHAR2(200);
OS_CHECK PLS_INTEGER;
OS_TYPE varchar2(8);
B_OUTPUT varchar2(20);
M_OUTPUT varchar2(20);
ARCHIVE_LOG_MODE varchar2(20);


begin
OUTPUT_MESSAGE := 'NO';
/*Query to check the OS of the DB. Previously this is:
select dbms_utility.port_string into OS_STRING from dual
But the query only works on 11g dataguard on read only mode.
*/

select BANNER into OS_STRING from v$version where BANNER like 'TNS%';

select database_role into db_role from v$database;
select instance_number into db_inst from v$instance;
select count(*) into L0 from v$backup_set where Incremental_level=0 and completion_time > sysdate - 8;
select count(*) into L1 from v$backup_set where Incremental_level=1 and completion_time > sysdate - 2;
select count(*) into ARC_BACKUP from v$backup_set where incremental_level is null and backup_type='L' and completion_time > sysdate-8/24;
/*CHECK OS WIN server does not have archive log backup only archive log copy
Replaced the WIN to Windows to accomodate the Query for OS check
*/
OS_CHECK:=INSTR(OS_STRING,'Windows');
IF OS_CHECK >0 THEN
OS_TYPE :='WIN';
end if;
OS_CHECK:=INSTR(OS_STRING,'Linux');
IF OS_CHECK >0 THEN
OS_TYPE :='Linux';
end if;

/*Check if DB is a primary DB. Primary DB, */
if db_role='PRIMARY' then
db_rolec := 0;
else
db_rolec := 1;
end if;

/*Check if Instance 1. Applicable in RAC database since Node 1 holds the backup scripts. */
if db_inst=1 then
db_instc := 1;
end if;

/*Check if DB is archived log mode. Reporting DB has archiving disabled. False alarm will happen if this check is not added in script. */
if db_rolec=0 or db_instc=0 THEN
select log_mode into ARCHIVE_LOG_MODE from v$database;
end if;

/* First check: If db node is 2 or dataguard is found, the script will error in exit.*/
if db_rolec=1 or db_instc=0 or ARCHIVE_LOG_MODE='NOARCHIVELOG' or OS_TYPE= 'WIN' THEN
OUTPUT_MESSAGE := 'NO';
else
/* Dynamic sql are to avoid getting error on node B standby. Dynamic SQL output will captured by variables using execute immediate. */
L00_stmt := 'select  NVL(min(r.status),''NO BACKUP'') from V$RMAN_BACKUP_JOB_DETAILS r inner join (select distinct session_stamp, incremental_level from v$backup_set_details) b on r.session_stamp = b.session_stamp where incremental_level is not null and r.start_time > sysdate - ('||L0_threshold||'+'||g_period||')/24 and b.incremental_level = 0';
L11_stmt := 'select  NVL(min(r.status),''NO BACKUP'') from V$RMAN_BACKUP_JOB_DETAILS r inner join (select distinct session_stamp, incremental_level from v$backup_set_details) b on r.session_stamp = b.session_stamp where incremental_level is not null and r.start_time > sysdate - ('||L1_threshold||'+'||g_period||')/24 and b.incremental_level = 1';
L001_stmt := 'select NVL(min(r.status),''NO BACKUP'') from V$RMAN_BACKUP_JOB_DETAILS r inner join (select distinct session_stamp, incremental_level from v$backup_set_details) b on r.session_stamp = b.session_stamp where incremental_level is not null and r.start_time > sysdate - 1 and b.incremental_level = 0';
/* SQL will be replaced by this in the future
select distinct a.session_stamp,a.status from V$RMAN_BACKUP_JOB_DETAILS a join
v$backup_set_details b
on a.session_stamp=b.session_stamp
where
a.start_time > sysdate - 20 and
b.incremental_level=0
*/
EXECUTE IMMEDIATE L00_stmt into L00;
EXECUTE IMMEDIATE L11_stmt into L11;
EXECUTE IMMEDIATE L001_stmt into L001;
/* END of Dynamic SQL */
/* Main Logic, If the logic passed in the first check this will determine if there will be any error. */

IF L0 = 0 or L1 = 0 or ARC_BACKUP = 0 or L00 = 'NO BACKUP' or L11 = 'NO BACKUP' or L11='FAILED' or L00 = 'RUNNING' or L00 = 'FAILED' then /* First pass, any failures on the backup will be checked here*/
IF L0 = 0 or L00='NO BACKUP' or L00='RUNNING' or L00 = 'FAILED' THEN
OUTPUT_MESSAGE := 'LEVEL 0';


ELSIF (L1 = 0 or L11='NO BACKUP' or L11='FAILED') and L001 = 'NO BACKUP' THEN
OUTPUT_MESSAGE := 'LEVEL 1';


ELSIF ARC_BACKUP = 0 THEN
if OS_TYPE ='Linux' then
OUTPUT_MESSAGE := 'ARCHIVE';


end if;
end if;
end if;
end if;
dbms_output.put_line(OUTPUT_MESSAGE||' BACKUP FAILURE.');
--select OUTPUT_MESSAGE ,'BACKUP_FAILURE' INTO B_OUTPUT,M_OUTPUT from dual;
end;

/


/*06/29/2016 -- Rommell - The current sql used by oem,which was provided by Glen, Only test if a certain backup failed. It does not test what kind of backup failed and it does not test if the backup is just a subset of a more "complete backup". A failed level 1 backup can be ignored if a level 0 backup completed and also an arc backup can be #ignored if a level 1 or level 0 backup completed.
OLD SQL select distinct replace(global_name, '.WORLD','') db_name, 1 from global_name, sys.v_$rman_status where start_time > Sysdate -26/24 and status not in ('COMPLETED','COMPLETED WITH WARNINGS','RUNNING');
08/16/2016 -- Rommell - Changed the sql monitoring script into a inner join so It can only take the status of the latest backup per type (INCR/ARCH);
09/22/2016 -- Rommell - Added the logic for the checking if there is backup failed or not.
09/29/2016 -- Rommell - Initialized var OUTPUT_MESSAGE on start. My test has this variable but somehow the one pasted on the link is the version that was not initialized
01/5/2016 -- Rommell - Changed the start_time to completion_time int the sql script driver.
10/7/2016 -- Rommell - Added check for OS type since Windows does not have any achive backup only OS copy and added check via diction v$rman_backup_job_details since there are failure not detected in v$backup_set
10/19/2016 -- Rommell - Added "select OUTPUT_MESSAGE ,'BACKUP_FAILURE' INTO B_OUTPUT,M_OUTPUT from dual;" as requested by Glen
11/12/2016 -- Rommell -- Added capability to check archiving. If archiving if disabled, No backup failure is the output.
02/02/2017 -- Romme Fixed Logic on checking of Node number. Failures are being output on Node 2 databases.
from if db_rolec=1 or db_instc=1 or ARCHIVE_LOG_MODE='NOARCHIVELOG'
To if db_rolec=1 or db_instc=0 or ARCHIVE_LOG_MODE='NOARCHIVELOG' or OS_TYPE= 'WIN' THEN
Also corrected the commenting of lines.
05/31/2017 -- Ravi - Modified logic in db_rolec and Added grouping on the logic --> IF (L0 = 0 and L1 = 0) or ARC_BACKUP = 0 or L00 != 'COMPLETED' or L11 != 'COMPLETED' then
07/07/2017 -- MikeP/Rommell - The previous query to check OS version fails on dataguard. Replaced dbms_utility.port_string and just used v$version to get the OS version of the DB Server.
07/10/2017 -- Rommell - Added checks. Previous logic will output L1 backup failure eventhough there is an available (less then 24 hour) L0 Backup. -- FIXED.
07/13/2017 -- Rommell/MikeP -- Mike found out that the metric does not work on Standby Node B. The issue is because the rman views is invalid on Node B standby, optimizer has to look for all the views used by the script, an invalid view will output error. Dynamic sql is needed so optimizer will not get an error looking in data dictionary cache since the script will skip
the sql once metric has detected that it is running on standby.
08/31/2017 -- Rommell/MikeP -- Mike found, during the testing, that deliberate L1 backup fails. The cause is when the backup deliberately fails, the output of the script is FAILED and NO BACKUP -- Which was not capture by the logic. Added the workd FAILED in the status check of the logic.
09/17/2017 -- Rommell 170916-000801 - L1 backup failure alert eventhough L0 backup completed 16 hours ago, it should output NO backup failure but it output L1.
Upon checking the issue is the OR in the Main logic should be AND. This is now fixed.
12/24/2017 -- Rommell - Remove the rule hint and replaced by CBO, my test shows less sorting on CBO than RULE.
12/29/2017 -- Rommell/MikeP - Since the alerts has been coming in bulk on mondays(gets auto closed after some hours) added a 12 hour grace period to the threshold on L0 and L1 backup
So instead of (sysdate - 1) for L1 and (sysdate - 7) for L0, I converted the days to hours so I can add the 12 hour grace period. It is now (sysdate-180/24) for L0 and (sysdate-36/24) for L1
Added the g_period, l1_threshold and L0_threshold variable to remove the hardcoded threshold values.

*/
