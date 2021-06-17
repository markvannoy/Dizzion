<#
.SYNOPSIS
	Connect to all specified vCenter clusters, enumerate all the VMs on each
    cluster, enumerate all the snapshots each VM has, and remove VM snapshots
    that are as old as or older than specified days.
	
.DESCRIPTION
    This script is intended to run under a valid service account that is e-mail
    enabled such that the service account has sufficient priviliges to both
    list and remove snapshots.  Currently the scipt is command line drive in
    order to reduce the dependency on external files and modules.  However,
    it would be relatively easy to add the ability to specify parameters in a
    JSON file.  Additonally, it is possible to specify credentials interactively
    for an account that is authorized to send e-mail if the service account
    this script is run under lacks e-mail capability.  One e-mail will be sent
    that summarizes all snapshots that were removed from all clusters.

    The easiest way to use this script is to simply fill in the parameters with
    the environment's actual parameters then run the script with no options
    under an appropriate service account.

    WARNING: Snapshots will be deleted without any prompting or other human
    interaction.  Use with caution!

.PARAMETER Days
    Number of days old or older to remove snapshots.  For example, if the
    default of 30 is used then all snapshots that are 30 days old or older
    will be removed.

.PARAMETER Clusters
    The comma separated list of vCenter clusters to connect to and process
    snapshots. 

.PARAMETER MailServer
    The E-mail server to use for sending out e-mail alerts.

.PARAMETER To
    The comma separated list of e-mail addresses to send alerts to.

.PARAMETER Tags
    This is an optional additional filter to limit what VMs are targeted.  For
    instance, if all VM's are tagged with a customer name then the Tags option
    could specify a specific customer's tag, or tags, to ensure that only their
    VM's are targeted across all clusters.

.PARAMETER ReadOnly
    This switch will send the report of what would have been done if snapshots
    were removed.  This is a handly switch for non-destructive audits.

.PARAMETER NotMailEnabled
    Set this switch to prompt for e-mail credentials interactively in cases
    in which the service account does not have e-mail access to send the
    summary e-mail

.EXAMPLE
	.\Remove-Snapshots.ps1 -Clusters 'server1, server2, server3' -MailServer 'smtp' -To 'distlist'

   Connects to server1, then server2, and then server3 with processing of VMs
   occurring on each server before proceeding to the next server.  An e-mail
   summary will be sent to distlist using the server smtp.

   This example is overly artificial.  All names should be fully qualified.
   Each server would be specified along the lines of server1.somewhere.com or
   smtp.somewhere.com and the distribution list being sent to would need to be
   listed as distlist@somewhere.com.  The names were shortened to make the
   example more readable.
	

.NOTES
    FileName:    Remove-Snapshots.ps1
    Author:      Mark Van Noy
    Created:     06/17/2021
    
    Version history:
    1.0.0 - (06/17/2021) Script created
#>

[CmdletBinding()]
param
(
   [Parameter(Mandatory = $False, HelpMessage = "How old, or older, snapshots need to be in order to be removed")]
   [ValidateNotNullOrEmpty()]
   [Int]$Days = 30,

   [Parameter(Mandatory = $False, HelpMessage = "List of cluster names of vCenter servers to connect to")]
   [ValidateNotNullOrEmpty()]
   [String[]]$Clusters = @(''),

   [parameter(Mandatory=$False, HelpMessage="E-mail server to send mail through.")]
   [ValidateNotNullOrEmpty()]
   [String]$MailServer = "",

   [parameter(Mandatory=$False, HelpMessage="Comma separated e-mail addresses to send alerts to.")]
   [ValidateNotNullOrEmpty()]
   [String]$To = '',

   [Parameter(Mandatory = $False, HelpMessage = "List of tags to limit the VMs targeted")]
   [String[]]$Tags,

   [Parameter(Mandatory = $False, HelpMessage = "Only report on the snapshots, do not delete")]
   [switch]$ReadOnly,

   [Parameter(Mandatory = $False, HelpMessage = "Prompt for e-mail credentials")]
   [switch]$NotMailEnabled
)

# Set the e-mail Subject
$subject = "Snapshot Cleanup Report"

# Initialize the e-mail message/body
if ($ReadOnly)
{
   $message = "Running in ReadOnly mode.  NO OPERATIONS WERE PERFORMED.`r`n"
   $message += "========================================================`r`n`r`n"
}
else
{
   $message = ""
}

# Store today's date for later date math
$date = Get-Date

# Prompt for e-mail credentials if the service account does not have e-mail enabled
if ($NotMailEnabled)
{
   # Need to get the proper credentials to send an e-mail
   $emailCredentials = Get-Credential -Message "Please enter login and password for the e-mail account to send mail from"
   $username = $emailCredentials.UserName
}
else
{
   $username = [System.Environment]::UserName
}

# Step through each specified cluster. Large numbers of clusters and VM's could take a while to process.
foreach ($cluster in $Clusters)
{
   try
   {
      # Connect to a specified vCenter server; one needed per vSphere cluster
      $vcenter = Connect-VIServer -Server $cluster -Protocol HTTPS -ErrorAction Stop
   }
   catch
   {
      Write-Host -ForegroundColor Red "Failed to connect to vCenter cluster: $($cluster)"
      continue
   }

   # Gets all VM's on a vCenter cluster using tags if they are specified.
   if ($Tags)
   {
      try
      {
         $vms = Get-VM -Server $cluster -Tag $Tags -ErrorAction Stop
      }
      catch
      {
         Write-Host -ForegroundColor Red "Could not find VMs with tags: `"$($Tags)`" on vCenter cluster: $($cluster)"
         continue
      }
   }
   else
   {
      try
      {
         $vms = Get-VM -Server $cluster -ErrorAction Stop
      }
      catch
      {
         Write-Host -ForegroundColor Red "Could not find VMs on vCenter cluster: $($cluster)"
         continue
      }
   }

   # Step through each VM; sorted alphabetically
   foreach ($vm in ($vms | Sort-Object -Property Name))
   {
      # Set the header for the potential summary message
      $queue = "VM: $($vm)`r`n"
      $queue += "--------------------------------------------------`r`n"

      # Set flag for adding to message.  Default to False unless snapshots should be deleted.
      $addQueue = $False

      # Get all the snapshots the VM has
      $snapshots = Get-Snapshot -VM $vm
      foreach ($snapshot in $snapshots)
      {
         # Explicitly filter the snapshots, rather than piping, to only work on snapshots $Days old or older.
         if ($snapshot.Created -le $date.AddDays(-$Days)) 
         {
            # Simply formatting separation if multiple snapshots to list/delete
            if ($addQueue)
            {
               $queue += "`r`n     <==========>`r`n`r`n"
            }

            # At least one qualifying snapshot was found so add the queue to the message
            $addQueue = $True

            # build the $message and eventually send exactly one e-mail
            $queue += "Snapshot: $($snapshot.Name)`r`n"
            $queue += "Description:`r`n$($snapshot.Description)`r`n"
            $queue += "Created Date: $($snapshot.Created)`r`n"
            $queue += "Days old: $(($date - $snapshot.Created).Days)`r`n"

            # Only delete snapshots if the $Readonly switch is NOT specified; default is delete.
            if (!$ReadOnly)
            {
               # Remove the qualifying snapshot
               $removed = Remove-Snapshot -Snapshot $snapshot -Confirm:$False # -RunAsync as an improvement to performance
            }
         }
      }

      $queue += "--------------------------------------------------`r`n`r`n`r`n`r`n"

      # Add built up queue message to final outgoing message if appropriate
      if ($addQueue)
      {
         $message += $queue
      }
   }

   # Disconnect from the View server without prompting; cleanup after ourselves.
   Disconnect-VIServer -Server $vcenter -Force -Confirm:$False
}

# Send the e-mail message. (Send-MailMessage defaults to logged in user if -Credential is not specified.)
try
{
   if ($NotMailEnabled)
   {
      Send-MailMessage -To $To -From "vCenter Snapshot Cleaner <$($username)@colorado.edu>" -Subject $subject -Body $message -SmtpServer $MailServer -Port 25 -UseSsl -Credential $emailCredentials -ErrorAction Stop
   }
   else
   {
      Send-MailMessage -To $To -From "vCenter Snapshot Cleaner <$($username)@colorado.edu>" -Subject $subject -Body $message -SmtpServer $MailServer -Port 25 -UseSsl -ErrorAction Stop
   }
}
catch
{
   Write-Host -ForegroundColor Red "Failed to connect to e-mail server: $($MailServer)"
   exit (1)
}