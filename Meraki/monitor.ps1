param (
    [string]$MerakiApiKey = "ce78a29c63a45eefb50edc23e219760fed57dd8d",
    [string]$OrganizationId = "1523712",
    [string]$Email = "user1@gmail.com"
    #[string]$ProxyAddress = "http://proxy-2-apj.svcs.entsvcs.com:8088"
)

# Variable to store previous device statuses
$previousDeviceStatuses = @{}
# Define a hashtable to keep track of the uplink downtime
$downUplinks = @{}
# Define a hashtable to keep track of last known status
$lastKnownStatus = @{}
        

function Send-Email {
    param (
        [string]$To,
        [string]$Subject,
        [string]$Body
    )

    $smtpServer = "smtp.gmail.com"
    $smtpFrom = "user2@gmail.com"
    $smtpPassword = "shshagahsjwsjsis"  # Use 16 character generated app password

    $smtp = New-Object Net.Mail.SmtpClient($smtpServer, 587)  # Use port 587 for Gmail SMTP with SSL/TLS
    $smtp.EnableSsl = $true
    $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpFrom, $smtpPassword)

    $message = New-Object system.net.mail.mailmessage
    $message.From = $smtpFrom
    $message.To.Add($To)
    $message.Subject = $Subject
    $message.Body = $Body

    try {
        $smtp.Send($message)
    } catch {
        throw "Failed to send email: $_"
    }
}


# Function to call Meraki API with optional proxy
function Invoke-MerakiApi {
    param (
        [string]$Url,
        [string]$Method = "GET",
        [object]$Body = $null
    )

    $headers = @{
        "X-Cisco-Meraki-API-Key" = $MerakiApiKey
    }

    $options = @{
        Uri = $Url
        Method = $Method
        Headers = $headers
        ContentType = "application/json"
        #Proxy = $ProxyAddress
    }

    if ($Body) {
        $options.Add("Body", ($Body | ConvertTo-Json))
    }

    try {
        $response = Invoke-RestMethod @options
        return $response
    } catch {
        Send-Email -To $Email -Subject "Meraki Script Error" -Body "Failed to execute API call: $($_.Exception.Message)"
        throw $_
    }
}

# Monitor device status and send email on change
function Monitor-DeviceStatus {
    $url = "https://api.meraki.com/api/v1/organizations/$OrganizationId/devices/statuses"

    try {
        $response = Invoke-MerakiApi -Url $url
        #Write-Host "Response:"
        #Write-Host $response | ConvertTo-Json -Depth 5

        foreach ($device in $response) {
            #Write-Host "Device $($device.serial) is $($device.status)"
            $deviceId = $device.serial
            $currentStatus = $device.status

            if ($previousDeviceStatuses.ContainsKey($deviceId)) {
                $previousStatus = $previousDeviceStatuses[$deviceId]
                if ($currentStatus -ne $previousStatus) {
                    #Write-Host "Device $deviceId status changed from $previousStatus to $currentStatus"
                    # Send email notification for status change
                    Send-Email -To $Email -Subject "Meraki Device Status Change Alert" -Body "Device $deviceId status changed from $previousStatus to $currentStatus"
                }
            }

            # Update previous status in global variable
            $previousDeviceStatuses[$deviceId] = $currentStatus
        }
    } catch {
        #Write-Host "Error fetching device status: $($_.Exception.Message)"
        # Send email notification for error
        Send-Email -To $Email -Subject "Meraki Device Status Error" -Body "Error fetching device status: $($_.Exception.Message)"
        # You can add additional error handling or logging here if needed
    }
}

# Monitor license status
function Monitor-LicenseStatus {
    $url = "https://api.meraki.com/api/v1/organizations/$OrganizationId/licenses/overview"

    try {
        $response = Invoke-MerakiApi -Url $url

        # If the response is a hashtable, convert it to JSON and then to a PowerShell object
        if ($response -is [hashtable]) {
            $responseObj = $response | ConvertTo-Json | ConvertFrom-Json
        } else {
            $responseObj = $response
        }

        # Access the expirationDate directly from the response object
        $expirationDate = $responseObj.expirationDate
        #Write-Host "Expiry Date: $expirationDate"

        # Remove the ' UTC' suffix and then parse the date
        $expirationDate = $expirationDate -replace ' UTC$', ''
        #Write-Host "Expiry Date After: $expirationDate"

        # Parse the date
        $expiryDate = [datetime]::ParseExact($expirationDate, 'MMM dd, yyyy', $null)
        #Write-Host "Parsed Expiry Date: $expiryDate"

        # Check if the license is expiring within the next 30 days
        $daysLeft = ($expiryDate - (Get-Date)).Days
        #Write-Host "Days Left: $daysLeft"
        if ($daysLeft -le 30) {
            Send-Email -To $Email -Subject "Meraki License Expiry Alert" -Body "License is expiring on $expiryDate ($daysLeft days left)"
        }
    } catch {
        Write-Host "Error fetching license status: $($_.Exception.Message)"
        # Handle the error, such as logging or sending an email
    }
}

# Monitor uplink status
function Monitor-UplinkStatus {
    $url = "https://api.meraki.com/api/v1/organizations/$OrganizationId/uplinks/statuses"

    try {
        $response = Invoke-MerakiApi -Url $url
        $currentTime = Get-Date

        foreach ($device in $response) {
            foreach ($uplink in $device.uplinks) {
                #Write-Host "Device Serial: $($device.serial)"
                #Write-Host "Uplink Interface: $($uplink.interface)"
                #Write-Host "Uplink Status: $($uplink.status)"

                $uplinkId = "$($device.serial)-$($uplink.interface)"

                if ($uplink.status -ne "active") {
                    if ($downUplinks.ContainsKey($uplinkId)) {
                        # Check if the uplink has been down for more than 10 minutes
                        $downDuration = $currentTime - $downUplinks[$uplinkId]
                        if ($downDuration.TotalMinutes -ge 10) {
                            # Send email or raise incident
                            Send-Email -To $Email -Subject "Meraki Uplink Down Alert" -Body "Uplink $($uplink.interface) on device $($device.serial) has been down for more than 10 minutes."
                            # Remove the uplink from the hashtable after raising the incident
                            $downUplinks.Remove($uplinkId)
                        }
                    } else {
                        # Record the time when the uplink was first detected as down
                        $downUplinks[$uplinkId] = $currentTime
                    }
                } else {
                    # Remove the uplink from the hashtable if it is active
                    if ($downUplinks.ContainsKey($uplinkId)) {
                        $downUplinks.Remove($uplinkId)
                    }
                }
            }
        }
    } catch {
        # Send an email if there is an error fetching the uplink status
        Send-Email -To $Email -Subject "Meraki Uplink Status Error" -Body "Error fetching uplink status: $($_.Exception.Message)"
    }
}

# Monitor Meraki VPN status and send email on status change
function Monitor-VPNStatus {
    $url = "https://api.meraki.com/api/v1/organizations/$OrganizationId/appliance/vpn/statuses"
    
    try {
        $response = Invoke-MerakiApi -Url $url
        #Write-Host "Response:"
        #Write-Host $response | ConvertTo-Json -Depth 5
        
        # Iterate through each network in the response
        foreach ($network in $response) {
            #Write-Host "Network: $($network.networkName)"
            
            # Monitor Meraki VPN peers for the current network
            foreach ($merakiPeer in $network.merakiVpnPeers) {
                $peerKey = "$($merakiPeer.networkId)-Meraki"
                #Write-Host $peerKey | ConvertTo-Json -Depth 5
                
                if (-not $lastKnownStatus.ContainsKey($peerKey)) {
                    $lastKnownStatus[$peerKey] = $merakiPeer.reachability
                }
                
                if ($merakiPeer.reachability -ne $lastKnownStatus[$peerKey]) {
                    #Write-Host "Meraki VPN Peer $($merakiPeer.networkName) in network $($network.networkName) has changed status to $($merakiPeer.reachability)"
                    # Send an email notification for status change
                    Send-Email -To $Email -Subject "Meraki VPN Peer Status Change Alert" -Body "Meraki VPN Peer $($merakiPeer.networkName) in network $($network.networkName) has changed status to $($merakiPeer.reachability)"
                    
                    # Update last known status
                    $lastKnownStatus[$peerKey] = $merakiPeer.reachability
                }
            }
            
            # Monitor third-party VPN peers for the current network
            foreach ($thirdPartyPeer in $network.thirdPartyVpnPeers) {
                $peerKey = "$($thirdPartyPeer.name)-ThirdParty"
                #Write-Host $peerKey | ConvertTo-Json -Depth 5
                
                if (-not $lastKnownStatus.ContainsKey($peerKey)) {
                    $lastKnownStatus[$peerKey] = $thirdPartyPeer.reachability
                }
                
                if ($thirdPartyPeer.reachability -ne $lastKnownStatus[$peerKey]) {
                    if ($thirdPartyPeer.publicIp) {
                        #Write-Host "Third-Party VPN Peer $($thirdPartyPeer.name) with IP $($thirdPartyPeer.publicIp) in network $($network.networkName) has changed status to $($thirdPartyPeer.reachability)"
                        # Send an email notification for status change
                        Send-Email -To $Email -Subject "Third-Party VPN Peer Status Change Alert" -Body "Third-Party VPN Peer $($thirdPartyPeer.name) with IP $($thirdPartyPeer.publicIp) in network $($network.networkName) has changed status to $($thirdPartyPeer.reachability)"
                    } else {
                        #Write-Host "Third-Party VPN Peer $($thirdPartyPeer.name) in network $($network.networkName) has changed status to $($thirdPartyPeer.reachability)"
                        # Send an email notification for status change
                        Send-Email -To $Email -Subject "Third-Party VPN Peer Status Change Alert" -Body "Third-Party VPN Peer $($thirdPartyPeer.name) in network $($network.networkName) has changed status to $($thirdPartyPeer.reachability)"
                    }
                    
                    # Update last known status
                    $lastKnownStatus[$peerKey] = $thirdPartyPeer.reachability
                }
            }
        }
    } catch {
        #Write-Host "Error fetching VPN status: $($_.Exception.Message)"
        # Handle the error, such as logging or sending an email
        Send-Email -To $Email -Subject "Meraki VPN Status Error" -Body "Error fetching VPN status: $($_.Exception.Message)"
    }
}

# Function to monitor firewall latency and loss
function Monitor-FirewallLatency {
    # Main URL for the organization's uplink statuses
    $url = "https://api.meraki.com/api/v1/organizations/$OrganizationId/uplinks/statuses"
    $response = Invoke-MerakiApi -Url $url

    foreach ($device in $response) {
        $serial = $device.serial

        foreach ($uplink in $device.uplinks) {
            $ipAddr = $uplink.primaryDns

            if ($ipAddr) {
                $url1 = "https://api.meraki.com/api/v1/devices/$serial/lossAndLatencyHistory?ip=$ipAddr&resolution=86400"
                #Write-Host "Requesting loss and latency history for device $serial, uplink IP $ipAddr"

                try {
                    $response1 = Invoke-MerakiApi -Url $url1 
                    #Write-Host "Next Response"
                    #Write-Host $response1 | ConvertTo-Json -Depth 5

                    foreach ($record in $response1) {
                        if ($record.lossPercent -gt 10) {
                            #Write-Host "Firewall $serial, uplink $ipAddr is experiencing high loss of $($record.lossPercent)%"
                            Send-Email -To $Email -Subject "Firewall interface High loss Alert" -Body "Device $serial, uplink (WAN Interface) $ipAddr is experiencing high loss of $($record.lossPercent)%"
                        }

                        if ($record.latencyMs -gt 100) {
                            #Write-Host "Firewall $serial, uplink $ipAddr is experiencing high latency of $($record.latencyMs) ms"
                            Send-Email -To $Email -Subject "Firewall interface High latency Alert" -Body "Device $serial, uplink (WAN Interface) $ipAddr is experiencing high loss of latency of $($record.latencyMs) ms"
                        }
                    }
                } catch {
                    #Write-Host "Failed to get loss and latency history for device $serial, uplink $ipAddr. Error: $_"
                    Send-Email -To $Email -Subject "Meraki Firewall Interface Loss/Latency Error" -Body "Error fetching Firewall Interface Loss/Latency: $($_.Exception.Message)"
                }
            }
        }
    }
}

# Define variables to monitor 15 minutes for any API endpoint failure
$firstTime = $null
$currentTime = $null
$timeDifference = $null 

# Main monitoring function
function Monitor-MerakiNetwork {
    try {
        Monitor-DeviceStatus
        Monitor-LicenseStatus
        Monitor-UplinkStatus
        Monitor-VPNStatus
        Monitor-FirewallLatency
    } catch {
         if ($firstTime -eq $null) {
             $firstTime = Get-Date
         }
         else {
             # Store the current time
             $currentTime = Get-Date

             # Calculate the time difference
             $timeDifference = New-TimeSpan -Start $firstTime -End $currentTime
         }
         # Check if the time difference is greater than or equal to 15 minutes
         if ($timeDifference.TotalMinutes -ge 15) {
             $firstTime = $null
             Send-Email -To $Email -Subject "Meraki Monitoring Script Error" -Body "The monitoring script encountered an error: $($_.Exception.Message)"
         }
    }
}

# To run & test for once, use this (comment/ uncomment below line using # as per need):
# Monitor-MerakiNetwork

<#
# Schedule the monitoring function to run periodically
while ($true) {
    Monitor-MerakiNetwork
    Start-Sleep -Seconds 300  # Run every 5 minutes
}
#>
