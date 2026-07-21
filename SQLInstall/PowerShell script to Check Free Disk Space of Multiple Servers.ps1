lll;<# 
            "SatNaam WaheGuru" 
 
Date: 24-Feb-2012 ; 14:31Pm 
Author: Aman Dhally 
Email:  amandhally@gmail.com 
web:    www.amandhally.net/blog 
blog:    http://newdelhipowershellusergroup.blogspot.com/ 
More Info :  
 
Version :  
 
    /^(o.o)^\  
 
 
#> 
 
 
 
clear 
$cre = get-Credential 'ms\npeadmrodriguezdk' # This user account should be Adminstrator  
$file = get-Content C:\SQLInstall\Computers.txt  # Replace it with your TXT file which contain Name of Computers  
 
foreach ( $args in $file) { 
get-WmiObject win32_logicaldisk -Credential $cre -ComputerName $args -Filter "Drivetype=3"  |  
ft SystemName,DeviceID,VolumeName,@{Label="Total SIze";Expression={$_.Size / 1gb -as [int] }},@{Label="Free Size";Expression={$_.freespace / 1gb -as [int] }} -autosize 
} 
 
## END OF SCRIPT ### 