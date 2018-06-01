#!/bin/bash
# set -x


# This script is launched by JAMF at the beginning of the setup process
# It performs the followings functions:
# 	Installs DEPNotify to allow for user setup and providing user feedback during the setup process
# 	Prompts the user for the Asset Tag and Location of the computer and computes Computer Name from this info
#	Assigns Computer Name and Updates JAMF based on this information
# 	Completes JAMF setup
# 	Reboots computer to allow user login


# Make we get the logged user for GUI purposes.
CURRENTUSER=$(python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')
RUNNINGUSER=$(whoami)
TMPLOC="/var/tmp/DEPNotify"
DNLOG="$TMPLOC/depnotify.log"
REGLOG="/var/temp/com.depnotify.registration.done"
DPNPATH="/Applications/DEPNotify.app/Contents/MacOS/DEPNotify"
JAMFURL="https://<<jamfurl>>.jamfcloud.com"											# URL of your JAMF server
JAMFBUILDAPI="JSSResource/buildings"
JAMFUSER=$4																					#Pass your API UserID as Argument 4
JAMFPW=$5																					#Pass your API Password as Argument 5
BUILDLIST="$TMPLOC/buildings.txt"
BUILDXML="$TMPLOC/buildings.xml"
BUILDNAMELIST="$TMPLOC/BuildingNameList.txt"
DEPNOTIFYPLIST="menu.nomad.depnotify"
DPNREGRESULTS="/Users/Shared/DEPNotify.plist"
DEP_NOTIFYID=77																				# Policy ID of the DEPNotify Installation Package
DETERMNUM=4
MODELTYPE=$(sysctl hw.model | awk '{print $2}')

AddCommand() {																				#Add a command to DEPNotify Log $1 is Command $2 is any text
	echo "Command: $1 $2" >> $DNLOG
}

UpdateStatus() {																			# Update Status in DEPNotify Log
	echo "Status: $1" >> $DNLOG
}

UpdatePlist() {																				# Pull a list of buildings from JAMF Server and update the DEPNotify Plist array
	# Let's get the building List from JAMF
	curl -k -u "$JAMFUSER":"$JAMFPW" "$JAMFURL/$JAMFBUILDAPI" -X GET -o "$BUILDXML" -H "accept: application/xml"

	# Convert to a list of buildings
	# Assumes buildings start wiht A-Z, a-z, or 0-9
	echo 'cat //buildings/building/name/text()' | xmllint --shell $BUILDXML | grep "^[A-Za-z1-9]" | sort > $BUILDLIST

	# Delete any existing building Array in DepNotify Plist
	sudo -u $CURRENTUSER defaults delete $DEPNOTIFYPLIST UIPopUpMenuUpper

	#Read building List and add to DEPNotify Plist
	while read LINE; do
				sudo -u $CURRENTUSER defaults write $DEPNOTIFYPLIST UIPopUpMenuUpper -array-add "$LINE"
		done < $BUILDLIST
}

GenerateComputerName() {																	# Generate Computer Name based on Building, Mac Type (DT/LT), and Asset Tag
#Get Location Prefix from text file
	PREFIX=$(cat $BUILDNAMELIST | grep "$LOC" | awk -F, '{print $2}')
	if [[ $PREFIX == "" ]]; then
		PREFIX=="XXX"
	fi

	COMPUTERNAME=$PREFIX
	if [[ ${MODELTYPE:0:7} == "MacBook" ]];
		then COMPUTERNAME+="LT"
		else COMPUTERNAME+="DT"
	fi
	COMPUTERNAME+=$ASSETTAG
	COMPUTERNAME+="Mac"
	echo $COMPUTERNAME
}

CleamUpDPN() {
# Let's Clean-up DEPNotify files just incase there is any stragglers left over
	rm /var/tmp/com.depnotify.* 															# Removes Registration and Provisioning BOMs from /var/tmp
	rm $DPNREGRESULTS																		# Removes Previous DPN registration files
	sudo rm -r $TMPLOC																		# Removes temporary location for files
	sudo rm -r $DPNPATH																		# Removes Application
	sudo rm "/Users/$CURRENTUSER/Library/Preferences/$DEPNOTIFYPLIST.plist"					# Removes Default plist for DEPNotify
}

#check to see if run as root
if [[ $RUNNINGUSER != "root" ]]; then
	echo "Must run as root"
	exit 1
fi

# Clean up from previous run (if necessary)
CleamUpDPN

# Make the Temporary directory
if [[ ! -f "$TMPLOC/" ]]; then
	mkdir $TMPLOC
	chmod -R 777 $TMPLOC
fi

# Create a new log file
touch $DNLOG

# Download DEPNotify and install from JAMF if not already installed
if [[ ! -f $DPNPATH ]]; then
	sudo jamf policy -id $DEP_NOTIFYID
fi

#Copy Plist from tmp location
cp $TMPLOC/menu.nomad.depnotify.plist /Users/$CURRENTUSER/Library/Preferences/

#Update Plist with building Array
UpdatePlist

# Setup instal settings before launching DEPNotify
AddCommand "MainTitle:" "Deploying Zones Mac"
AddCommand "MainText:" "Please wait while your computer is setup\nThis will take a few minutes\nEnjoy a cup of coffee while you wait."
AddCommand "WindowStyle:" "ActivateOnStep"
AddCommand "WindowSytle:" "NotMovable"
AddCommand "Image:" "/var/tmp/DEPNotify/Zones Logo Blue PNG.png"
AddCommand "NotificationOn:" ""
# AddCommand "Determinate:" "$DETERMNUM"
# AddCommand "DeterminateManual:" "0"

#Kick-off DEP_Notify
sudo -u $CURRENTUSER $DPNPATH -path $DNLOG -fullScreen &> /var/tmp/depnotifyoutput.log &

UpdateStatus "Welcme to your shiny new Mac. Please click continue..."
AddCommand "ContinueButtonRegister:" "Continue"

# Check every 1 second to see if the user responded to the prompts
while [[ ! -f /var/tmp/com.depnotify.registration.done ]]; do
	sleep 1
done

# Set Computer Name and Location in JAMF
LOC=$(sudo -u $CURRENTUSER  defaults read $DPNREGRESULTS "Location")
ASSETTAG=$(sudo  -u $CURRENTUSER defaults read $DPNREGRESULTS "Asset Tag")

COMPUTERNAME=$(GenerateComputerName)

UpdateStatus "Setting computer name to $COMPUTERNAME and location to $LOC"
sudo jamf setComputerName -name $COMPUTERNAME
sudo jamf recon -assetTag $ASSETTAG -building "$LOC"


UpdateStatus "Installing JAMF Policies"
sudo jamf policy -event Continue_Setup 														# Run Policies that are Initial_Setup
sudo jamf policy -event 																	# Run any policies that might be computer specific before restart

UpdateStatus "Installing all macOS Updates"
sudo jamf runSoftwareUpdate

UpdateStatus "Provisioning is now complete. We will now restart your computer."
AddCommand "ContinueButton:" "Restart"
sudo rm $DNLOG

#Don't clean up until the user clicks Continue
while [[ ! -f /var/tmp/com.depnotify.provisioning.done ]]; do
	sleep 1
done

#Clean up files
cp $DNLOG "/var/log/depnotify.log"
CleamUpDPN

#Restart the computer
shutdown -r now
exit 0
