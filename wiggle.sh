#!/bin/bash

export DB_FILE=wiggle.db
export COOKIE_FILE=.cookies.txt

# testmode means that it will only run 1 background cycle and then stop.  
# This allows you to test functionality without the background process running perpetually.  
# Eventually we will have an option in the database that indicates that we will have automatic processing, and this will be less useful.
TESTMODE=0
if [ "$1" = "--test" ]; then
  TESTMODE=1
fi


# Note this script is written in bash using the minimum.  Meant to be able to run easily on almost any linux platform, normally without needing to install anything.
# It requires:
#  - bash
#  - curl
#  - sqlite3
#  - dialog
#  - sed






function create_db_file() {

  # Initial database schema.  Once there is data in the file, any changes will need to be done differently.
  cat > db.sql << EOF

CREATE TABLE Config (
  Version INTEGER,
  URL TEXT DEFAULT NULL,
  ProcessingStop INTEGER DEFAULT 0
);

INSERT INTO Config (Version) VALUES (1);

-- Status:
--   0 = Not Set
--   1 = Download all
--   2 = Ignore (do not download or ask to download)
--   3 = Ask each item in this category.
CREATE TABLE Categories (
  CategoryID INTEGER PRIMARY KEY,
  Category STRING,
  Status INTEGER DEFAULT 0
);

-- Status:
--   0 = Unknown
--   1 = Available
--   2 = Deleted
--
-- Size: (in KB)
--
-- Download:
--  0 - Unset
--  1 - Download.
--  2 - Downloaded.
-- 99 - Dont Get.
CREATE TABLE Items (
  ItemID INTEGER UNIQUE,
  Status INTEGER DEFAULT 0,
  Title STRING,
  Size INTEGER,
  CategoryID INTEGER,
  Seeders INTEGER DEFAULT 0,
  Leechers INTEGER DEFAULT 0,
  LastCheck DATETIME,
  Download INTEGER DEFAULT 0
);

EOF

  sqlite3 $DB_FILE < db.sql
  local RESULT=$?
  rm db.sql
  return $RESULT
}

# This query function will allow us to perform an operation, but wait for 20 seconds if the file is locked.  Otherwise we end up with complicated results as you never know if your operation will succeed or not (because we have operations running in the background).  This does also mean that each query we make should not take longer than 20 seconds or this can cause problems.  Might pay to increase this to something much larger, but I dont know how large is too large.
function query() {
	sqlite3 -init <(echo ".timeout 20000") $DB_FILE "$1" 2>/dev/null
}


## Check the contents of the database, and determine if we need to make changes to it.
function check_db_version() {

	# check the current version
	local VERSION=$(query "SELECT Version FROM Config;")
#	echo "Current DB Version: $VERSION"
	
	# if we want to make changes to the database structure, we do it here, bringing it up to the expected version.
	if [ $VERSION -eq 1 ]; then
		# we need to modify the database so that the Config table is generic.  Basically a lookup table, that we can lookup any particular setting without having to modify the database (and make it incompatible).
		# Note that we are leaving URL in the original Config table.
		query "CREATE TABLE Settings (Name TEXT UNIQUE, Value TEXT DEFAULT NULL);"
		
		VERSION=2
		query "UPDATE Config SET Version=$VERSION;"
	fi
}


## The URL for the site should be in the database.
function data_site_url() {
	local URL=$(query "SELECT URL FROM Config;")
	if [ -z "$URL" ]; then
		URL=FAIL
	fi
	echo "$URL"
}

function get_setting() {
	local NAME=$1
	local VALUE=$(query "SELECT Value FROM Settings WHERE Name='$NAME';")
	echo "$VALUE"
}

function set_setting() {
	local NAME=$1
	local VALUE=$2
	local VNAME=$(query "SELECT Value FROM Settings WHERE Name='$NAME';")
	if [ -z "$VNAME" ]; then
		# No Setting.
		query "INSERT INTO Settings (Name, Value) VALUES ('$NAME', '$VALUE');"
	else
		query "UPDATE Settings SET Value='$VALUE' WHERE Name='$NAME';"
	fi

}


function get_latest_id() {
	local URL=$(data_site_url)
	curl -s --cookie $COOKIE_FILE --cookie-jar $COOKIE_FILE "${URL}alltorrents.php" | grep "torrentprofile.php?fid="|head -n 1|grep -o "fid=[0-9]*"| awk -F= {'print $2'}
}


# if we have the text of a category, need to get the ID for it.  If an ID doesn't exist, create one.
function get_category_id() {
	STR=$1
	
	local CAT_ID=$(query "SELECT CategoryID FROM Categories WHERE Category LIKE '$STR';")
	if [ -z "$CAT_ID" ]; then
		# No Category ID was found.
		CAT_ID=$(query "INSERT INTO Categories (Category) VALUES ('$STR'); SELECT last_insert_rowid();")
	fi
	echo "$CAT_ID"
}


# this function will get information about a particular FID, and add the details to the database.  This function assumes that the FID is not already in the database.  A seperate function which is similar will be used to update the FID details.
function process_fid() {

	local FID=$1

	# get the torrent info page.
	local URL=$(data_site_url)
	curl -s --cookie $COOKIE_FILE --cookie-jar $COOKIE_FILE ${URL}torrentprofile.php?fid=$FID>$FID.dos
	local GETRESULT=$?
	if [ $GETRESULT -ne 0 ]; then
	  echo "Received error code from site: $GETRESULT"
	  sleep 5
	else
		grep -q "Torrent info" $FID.dos
		if [ $? -eq 0 ]; then
			tr -d '\015' <$FID.dos >$FID.full
			rm $FID.dos

			grep -A 10 "gettorrent.php" $FID.full > $FID.sub
			rm $FID.full

			# strip out the stuff I dont want from the HTML.
			cat $FID.sub | sed -e 's/<\/td>//g'| sed -e 's/<\/a><\/b>//g'| sed -e 's/<td ><b><a href="gettorrent.php?fid=$FID">//g'|sed -e 's/<td width="70">//g'|sed -e 's/<td width="1">//g'|sed -e 's/<\/tr>//g'|sed -e 's/\t//g'|sed -e 's/&nbsp;/ /g'|sed -e 's/<td ><b><a href="gettorrent.php?fid=//g'|sed -e "s/'//g" > $FID.info
			rm $FID.sub

			sed -n 1,1p $FID.info > $FID.title
			sed -n 4,4p $FID.info > $FID.size
			sed -n 6,6p $FID.info > $FID.cat
			sed -n 7,7p $FID.info > $FID.seeders
			sed -n 8,8p $FID.info > $FID.leechers
			rm $FID.info

			local TITLE=`cat $FID.title|awk -F\> '{print $2}'`
			local SEEDERS=`cat $FID.seeders`
			local LEECHERS=`cat $FID.leechers`
			local CATEGORY=`cat $FID.cat|awk -F= {'print $3'}| sed -e 's/"//g'|sed -e 's/ \/>//g'`
			local CATMD5=`cat $FID.cat|md5sum`

			local SIZE_A=`cat $FID.size|awk {'print $1'}`
			local SIZE_B=`cat $FID.size|awk {'print $2'}`
			local SIZE=0

			case "$SIZE_B" in
				KiB) 
					SIZE=$SIZE_A
					;;
				MiB)
					SIZE=$(awk "BEGIN {print (($SIZE_A)*1024)}")
					;;
				GiB)
					SIZE=$(awk "BEGIN {print (($SIZE_A)*1024*1024)}")
					;;
				TiB)
					SIZE=$(awk "BEGIN {print (($SIZE_A)*1024*1024*1024)}")
					;;
				Bytes)
					SIZE=$(awk "BEGIN {print (($SIZE_A)/1024)}")
					;;
				*)
					echo "Unknown Size type: $SIZE_B"
					SIZE=$SIZE_A
					;;
			esac
		
			rm $FID.title $FID.size $FID.seeders $FID.leechers $FID.cat

			echo "Adding FID:$FID to database"
			
			# We have all the data, now we need to add it to the database.
			local CAT_ID=$(get_category_id "$CATEGORY")
			query "INSERT INTO Items (ItemID, Status, Title, Size, CategoryID, Seeders, Leechers, LastCheck, Download) VALUES ($FID, 1, '$TITLE', $SIZE, $CAT_ID, $SEEDERS, $LEECHERS, datetime('now'), 0);"
		else
			# we need to actually verify that the site says the torrent doesn't exist.
			grep -q "Torrent not found" $FID.dos
			if [ $? -eq 0 ]; then
				echo "FID:$FID doesn't exist"
				query "INSERT INTO Items (ItemID, Status, LastCheck) VALUES ($FID, 2, datetime('now'));"
			else
				echo "An unexpected result was received.  Please check the integrity of the site."
				echo "If changes to the site have invalidated this script, it will need to be modified."
			fi
			
			rm $FID.dos
		fi
	fi
}


function download_fid() {
	local ID=$1
	
	# Get Download Path
	local DPATH=$(get_setting "DownloadDir")
	
	echo "Downloading: $ID"

	local URL=$(data_site_url)
	curl -s --cookie $COOKIE_FILE --cookie-jar $COOKIE_FILE "${URL}gettorrent.php?fid=$ID" >$DPATH/$ID.torrent
	if [ $? -ne 0 ]; then
		echo "Unabled to download: $ID"
	else
		echo "Item $ID Downloaded"
		query "UPDATE Items SET Download=2 WHERE ItemID=$ID"
	fi
}



# this function will be run on the background (normally).  
# It will cycle through a number of tasks.  
# It will check for a particular entry in the database which will tell it to stop.
function process_tasks() {

	local SITE_ID=$1

	RUN_STATE=0
	while [ $RUN_STATE -eq 0 ]; do
	
		# --- get item details for newer items on the site.
 		local DB_ITEM_ID=$(query "SELECT ItemID FROM Items ORDER BY ItemID DESC LIMIT 1;")
 		if [ -z "$DB_ITEM_ID" ]; then
			DB_ITEM_ID=0
		fi
 		if [ $DB_ITEM_ID -lt $SITE_ID ]; then
			NEXT_ID=$((DB_ITEM_ID+1))
			echo "Getting $NEXT_ID"
			process_fid $NEXT_ID
 		fi
 		
 		# --- download files that have been marked for download.
 		local DL_ID=$(query "SELECT ItemID FROM Items WHERE Status=1 AND Download=1 AND Seeders>0 ORDER BY LastCheck, ItemID DESC LIMIT 1")
 		if [ -n "$DL_ID" ]; then
			download_fid $DL_ID
 		fi
		
		sleep 1
	
		RUN_STATE=$(query "SELECT ProcessingStop FROM Config;")
	done

	echo "Background Tasks Stopped"
}


function category_menu() {
	# display the menu for categories.

	local CHOICE=continue
	
	while [ "$CHOICE" != "EXIT" ]; do
	
		dialog \
		--title "Categories" \
		--begin 3 50 --tailboxbg process.log 30 78 \
		--and-widget \
		--begin 3 10 --no-tags --menu "Category Menu" 20 10 10 LIST List... EXIT Exit 2>menu.out
		local DRES=$?
		CHOICE=$(cat menu.out)
		rm menu.out
		
		if [ $DRES -eq 0 ]; then
			case "$CHOICE" in
				LIST)	
					dialog --msgbox "LIST." 5 30 
					;;
				EXIT)
					;;
				*)
					dialog --msgbox "Unknown." 5 30
					;;
			esac

		else
		  CHOICE=EXIT
		fi
	done
}


# process any new categories that have been added.  If there is nothing more to process, then it will return 1.
function process_categories() {

	local CHOICE=none
	local CATID=$(query "SELECT CategoryID FROM Categories WHERE Status=0 ORDER BY CategoryID LIMIT 1")
	
	while [ -n "$CATID" -a "$CHOICE" != "EXIT" ]; do
	
		# got a category, need to ask the user about.
		local CAT=$(query "SELECT Category FROM Categories WHERE CategoryID=$CATID")
		
		dialog --title "Wiggle" --begin 8 30 --infobox "New Category detected.\n\n  \"$CAT\"\n\nWhat do you want to do with this category?" 7 50 --and-widget --begin 18 50 --no-tags --no-cancel --no-ok --menu "Category Menu" 11 20 15 ASK "Ask Each Item" DOWNLOAD "Download All" IGNORE "Ignore All" EXIT Exit 2>menu.out
		local DRES=$?
		CHOICE=$(cat menu.out)
		rm menu.out
		
		if [ $DRES -eq 0 ]; then
			case "$CHOICE" in
				ASK)
					query "UPDATE Categories SET Status=3 WHERE CategoryID=$CATID"
					;;
				DOWNLOAD)
					query "UPDATE Categories SET Status=1 WHERE CategoryID=$CATID"
					query "UPDATE Items SET Download=1 WHERE CategoryID=$CATID AND Download=0 AND Seeders>0"
					;;
				IGNORE)
					query "UPDATE Categories SET Status=2 WHERE CategoryID=$CATID"
					query "UPDATE Items SET Download=99 WHERE CategoryID=$CATID AND Download=0"
					;;
				EXIT)
					;;
				*)
					dialog --msgbox "Unknown." 5 30
					;;
			esac

		else
		  CHOICE=EXIT
		fi
		
		if [ "$CHOICE" != "EXIT" ]; then
			CATID=$(query "SELECT CategoryID FROM Categories WHERE Status=0 ORDER BY CategoryID LIMIT 1")
		fi
	done
	
	local RES=0
	if [ "$CHOICE" = "EXIT" ]; then 
		RES=1
	fi
	return $RES
}

function process_items() {
	local CHOICE=none
	local ID=$(query "SELECT ItemID FROM Items WHERE Status=1 AND Download=0 AND Seeders > 0 ORDER BY LastCheck, ItemID DESC LIMIT 1")
	while [ -n "$ID" -a "$CHOICE" != "EXIT" ]; do
		# got a category, need to ask the user about.
		local TITLE=$(query "SELECT Title FROM Items WHERE ItemID=$ID")
		local CATID=$(query "SELECT CategoryID FROM Items WHERE ItemID=$ID")
		local SIZE=$(query "SELECT Size FROM Items WHERE ItemID=$ID")

		local CAT=$(query "SELECT Category FROM Categories WHERE CategoryID=$CATID")
		
		dialog --title "Wiggle" --begin 8 30 --infobox "New Item detected.\n\n Item ID: $ID\n Title: $TITLE\n Category: $CAT\n Size: $SIZE\n\nWhat do you want to do with this Item?" 11 90 --and-widget --begin 22 50 --no-tags --no-cancel --no-ok --menu "Item Menu" 12 30 15 DOWNLOAD "Download" IGNORE "Ignore" LATER "Ask again Later" MARK "Mark as Downloaded" EXIT Exit 2>menu.out
		local DRES=$?
		CHOICE=$(cat menu.out)
		rm menu.out
		
		if [ $DRES -eq 0 ]; then
			case "$CHOICE" in
				DOWNLOAD)
					query "UPDATE Items SET Download=1 WHERE ItemID=$ID"
					;;
					
				IGNORE)
					query "UPDATE Items SET Download=99 WHERE ItemID=$ID"
					;;
					
				LATER)
					query "UPDATE Items SET LastCheck=datetime('now') WHERE ItemID=$ID"
					;;
					
				MARK)
					query "UPDATE Items SET Download=2 WHERE ItemID=$ID"
					;;
				EXIT)
					;;
				*)
					dialog --msgbox "Unknown." 5 30
					;;
			esac

		else
		  CHOICE=EXIT
		fi
		
		if [ "$CHOICE" != "EXIT" ]; then
			ID=$(query "SELECT ItemID FROM Items WHERE Status=1 AND Download=0 AND Seeders > 0 ORDER BY LastCheck, ItemID DESC LIMIT 1")
		fi
	done
	
	local RES=0
	if [ "$CHOICE" = "EXIT" ]; then 
		RES=1
	fi
	return $RES
}


function process_items_advanced() {
	local CHOICE=none
	local ID=$(query "SELECT ItemID FROM Items WHERE Status=1 AND Download=0 AND Seeders>0 ORDER BY LastCheck, ItemID DESC LIMIT 10")
	
	while [ -n "$ID" -a "$CHOICE" != "EXIT" ]; do
	
		# got a category, need to ask the user about.
		local TITLE=$(query "SELECT Title FROM Items WHERE ItemID=$ID")
		local CATID=$(query "SELECT CategoryID FROM Items WHERE ItemID=$ID")
		local SIZE=$(query "SELECT Size FROM Items WHERE ItemID=$ID")

		local CAT=$(query "SELECT Category FROM Categories WHERE CategoryID=$CATID")
		
		
		dialog --title "Wiggle" --begin 8 30 --infobox "New Item detected.\n\n Item ID: $ID\n Title: $TITLE\n Category: $CAT\n Size: $SIZE\n\nWhat do you want to do with this Item?" 11 90 --and-widget --begin 22 50 --no-tags --no-cancel --no-ok --menu "Item Menu" 12 30 15 DOWNLOAD "Download" IGNORE "Ignore" LATER "Ask again Later" MARK "Mark as Downloaded" EXIT Exit 2>menu.out
		local DRES=$?
		CHOICE=$(cat menu.out)
		rm menu.out
		
		if [ $DRES -eq 0 ]; then
			case "$CHOICE" in
				DOWNLOAD)
					query "UPDATE Items SET Download=1 WHERE ItemID=$ID"
					;;
					
				IGNORE)
					query "UPDATE Items SET Download=99 WHERE ItemID=$ID"
					;;
					
				LATER)
					query "UPDATE Items SET LastCheck=datetime('now') WHERE ItemID=$ID"
					;;
					
				MARK)
					query "UPDATE Items SET Download=2 WHERE ItemID=$ID"
					;;
				EXIT)
					;;
				*)
					dialog --msgbox "Unknown." 5 30
					;;
			esac

		else
		  CHOICE=EXIT
		fi
		
		if [ "$CHOICE" != "EXIT" ]; then
			ID=$(query "SELECT ItemID FROM Items WHERE Status=1 AND Download=0 AND Seeders > 0 ORDER BY LastCheck, ItemID DESC LIMIT 1")
		fi
	done
	
	local RES=0
	if [ "$CHOICE" = "EXIT" ]; then 
		RES=1
	fi
	return $RES
}




# The Process menu will check the database for items that it needs to ask the user.  
# These would be:
#    - What to do with new categories.
#    - Should items be downloaded or not.
#
# This is written in a slightly weird way.. If the user actually exits while processing Categories, then we dont want to ask them to process the files.  
function process_menu() {
	process_categories && process_items
}

# Similar to the other process system, except it will show several items at a time, and allow you to select multiple, and then do something with it.
function adv_process_menu() {
	process_categories && process_items_advanced
}


function settings_menu() {
	local CHOICE=continue
	while [ "$CHOICE" != "EXIT" ]; do
		dialog \
		--title "Settings" \
		--begin 3 10 --no-tags --no-cancel --no-ok --menu "Settings" 13 35 6 URL "Site URL" DOWNLOAD "Download Location" EXIT Exit 2>menu.out
		local DRES=$?
		CHOICE=$(cat menu.out)
		rm menu.out
		
		if [ $DRES -eq 0 ]; then
			case "$CHOICE" in
				URL)
					local URL=$(query "SELECT URL FROM Config;")
					dialog --inputbox "Site URL" 8 50 "$URL" 2> dialog.output
					if [ $? -eq 0 ]; then
						local NEWURL=$(cat dialog.output)
						rm dialog.output
						query "UPDATE Config SET URL='$NEWURL'"
						dialog --msgbox "Setting Saved." 5 30
					fi
					;;
				DOWNLOAD)
					local VVAL=$(query "SELECT Value FROM Settings WHERE Name='DownloadDir'")
					dialog --inputbox "Download Directory" 8 50 "$VVAL" 2> dialog.output
					if [ $? -eq 0 ]; then
						local NEWVAL=$(cat dialog.output)
						rm dialog.output
						query "UPDATE Settings SET Value='$NEWVAL' WHERE Name='DownloadDir'"
						dialog --msgbox "Setting Saved." 5 30
					fi
					;;
				EXIT)
					;;
				*)
					dialog --msgbox "Unknown." 5 30
					;;
			esac
		else
		  CHOICE=EXIT
		fi
	done
}


function search_menu() {

	local LASTSEARCH=$(get_setting "LastSearch")

	# Ask the user what they are searching for.
	dialog --inputbox "Search for (SQL format)" 8 50 "$LASTSEARCH" 2> dialog.output
	if [ $? -eq 0 ]; then
		local SEARCH=$(cat dialog.output)
		rm dialog.output
		
		# Before searching, should get some parameters first.  Ie, do we want to ignore items that have no seeders... items that have already been downloaded or ignored? etc.
		dialog --notags --checklist "Search Options to include..." 10 70 8 SEEDERS "Select only items that have seeders" on DOWNLOADED "Select only items that have not been downloaded" on 2>menu.out
		grep -q SEEDERS menu.out && local ANDSEEDERS=" AND Seeders>0"
		grep -q DOWNLOADED menu.out && local ANDDL=" AND Download=0"
		rm menu.out
		
		set_setting "LastSearch" "$SEARCH"
		dialog --infobox "Searching... Please wait" 5 50
		
		# TODO: change all the spaces to %
		
		echo "#\!/bin/bash" > tmp_menu.sh
		echo "dialog --title \"Search Results\"  --notags --buildlist \"Press '$' for Selected column (right), press '^' for Selection column (left)\nPress Space to select an item.\n\nAfter selection is complete, you will be given options for the selection.\" 30 140 23 \\" >> tmp_menu.sh		
		
		query "SELECT ItemID FROM Items WHERE Title LIKE '%${SEARCH}%' $ANDSEEDERS $ANDDL ORDER BY Title" > db.output
		local LINES=$(cat db.output|wc -l)
		if [ $LINES -le 0 ]; then
			dialog --msgbox "No Results found." 5 30
		else
			# Since it can take a while to load up the titles from the ID list, best to provide some feedback so that the user knows it is doing something.
			local COUNTER=0
			(
			for ITEM in $(cat db.output) ;do
				local TITLE=$(query "SELECT Title FROM Items WHERE ItemID=$ITEM")
				### need to check for weird characters that might break the output....
				
				echo "$ITEM \"$TITLE\" off \\" >> tmp_menu.sh
				
				((COUNTER += 1))
				local PERC=$(awk "BEGIN {print ((($COUNTER)/($LINES))*100)}")
				echo "$PERC"
			done
			) | dialog --title " Retreiving Search Results " --guage "Please Wait..." 7 70 0
			
			echo "" >> tmp_menu.sh 
			chmod +x tmp_menu.sh 
			./tmp_menu.sh 2> select.output
			rm tmp_menu.sh
			
			# We need to build up the list of items that we selected, to display to the user.
			# Then we display a menu, where they can choose what to do with them (Download, Ignore, etc).
			
			test -e tmp.output && rm $_
			
			LINES=$(cat select.output|wc -w)
			if [ $LINES -gt 0 ]; then
				# Since it can take a while to load up the titles from the ID list, best to provide some feedback so that the user knows it is doing something.
# 				(
				for ITEM in $(cat select.output) ;do
					local TITLE=$(query "SELECT Title FROM Items WHERE ItemID=$ITEM")
					echo "$ITEM - $TITLE" >> tmp.output
				done
# 				) &
				
				dialog --title "Processing" --begin 3 50 --tailboxbg tmp.output 30 78 --and-widget --begin 35 75 --no-tags --no-cancel --no-ok --menu "Selection Menu" 12 30 15 DOWNLOAD "Download" IGNORE "Ignore" LATER "Ask again Later" MARK "Mark as Downloaded" EXIT Exit 2>menu.out
				local DRES=$?
				local CHOICE=$(cat menu.out)
				rm menu.out
				if [ $DRES -eq 0 ]; then
					case "$CHOICE" in
						DOWNLOAD)
							for ITEM in $(cat select.output) ;do
								query "UPDATE Items SET Download=1 WHERE ItemID=$ITEM"
								echo "Setting $ITEM to Download">>process.log
							done
							;;
							
						IGNORE)
							for ITEM in $(cat select.output) ;do
								query "UPDATE Items SET Download=99 WHERE ItemID=$ITEM"
								echo "Setting $ITEM to Ignore">>process.log
							done
							;;
							
						LATER)
							for ITEM in $(cat select.output) ;do
								query "UPDATE Items SET LastCheck=datetime('now') WHERE ItemID=$ITEM"
								echo "Setting $ITEM to Ask Later">>process.log
							done
							;;
							
						MARK)
							for ITEM in $(cat select.output) ;do
								query "UPDATE Items SET Download=2 WHERE ItemID=$ITEM"
								echo "Marking $ITEM as Downloaded">>process.log
							done
							;;
						EXIT)
							;;
						*)
							dialog --msgbox "Unknown." 5 30
							;;
					esac
				fi
# 				rm tmp.output
			fi
		fi
		rm db.output
		
		
		
# 		dialog --textbox db2.output 20 60
		
	fi
}


function main_menu() {
	# Display the main menu, and the background processing log.  Pressing Enter or Esc will result in the script exiting.

	local CHOICE=continue
	while [ "$CHOICE" != "EXIT" ]; do
		dialog \
		--title "Processing" \
		--begin 3 50 --tailboxbg process.log 30 78 \
		--and-widget \
		--begin 3 10 --no-tags --no-cancel --no-ok --menu "Main Menu" 13 25 6 PROCESS Process MULTIPROC Multi-Process SEARCH Search CAT Categories SETTINGS Settings EXIT Exit 2>menu.out
		local DRES=$?
		CHOICE=$(cat menu.out)
		rm menu.out
		
		if [ $DRES -eq 0 ]; then
			case "$CHOICE" in
				PROCESS)
					process_menu
					;;
				MULTIPROC)
					adv_process_menu
					;;					
				SEARCH)
					search_menu
					;;
				CAT)
					category_menu
					;;
				SETTINGS)
					settings_menu
					;;
				EXIT)
					;;
				*)
					dialog --msgbox "Unknown." 5 30
					;;
			esac
		else
		  CHOICE=EXIT
		fi
	done
}



######################################
# Main Process

# dialog --infobox "..." 5 50

# check for database file.
dialog --infobox "Checking for Database file: $DB_FILE" 5 50
if [ ! -e $DB_FILE ]; then
  dialog --infobox "Database file not found.\nCreating new database file." 6 50
  create_db_file
  if [ $? -ne 0 ]; then
	dialog --infobox "An unexpected error occurred while creating the database file." 5 50
	exit
  fi
fi

# Now that we know that the database exists, we need to check that it is up-to-date.
check_db_version

URL=$(data_site_url)
if [ "$URL" = "FAIL" ]; then
	dialog --infobox "URL is invalid." 5 50
	sleep 1

	dialog --inputbox "Please enter the URL of the site: " 7 50 2>output.txt
	URL=$(cat output.txt)
	rm output.txt
	query "UPDATE Config SET URL='$URL';"
fi

# check that we have a cookies file.
if [ ! -e $COOKIE_FILE ]; then
	dialog --infobox "Cookies file not found.\nWill require a login." 5 50
	sleep 1
	
	dialog --inputbox "Enter the username: " 7 50 2>output.txt
	FUSER=$(cat output.txt)
	rm output.txt
	
	dialog --passwordbox "Enter the password: " 7 50 2>output.txt
	FPASS=$(cat output.txt)
	rm output.txt
	
	dialog --infobox "Attempting to login.  Please wait." 5 50
	
	#login, but we dont care about the output as long as a cookie file is created.
	curl --cookie $COOKIE_FILE --cookie-jar $COOKIE_FILE --data "form_sent=1&redirect_url=index.php&req_username=$FUSER&req_password=$FPASS" ${URL}login.php?action=in >/dev/null
	if [ $? -ne 0 ]; then
		dialog --infobox "Something failed when logging in." 5 50
		sleep 5
		exit 1
	else
		# there should be a cookies file now.
		if [ ! -e $COOKIE_FILE ]; then
			dialog --infobox  "Cookies file doesn't exist, but it should." 5 50
			sleep 5
			exit 1
		fi
	fi
fi

# we have a cookies file, and we have the URL, so we can continue.
# Note, that the URL in the $URL variable will not be used in the sub-functions.  They will be obtained locally within each function.  Changing it here, will not affect the sub-functions.

DOWNDIR=$(get_setting "DownloadDir")
if [ -z $DOWNDIR ]; then
	dialog \
		--title "Enter Download directory for torrent files" \
		--begin 5 20 \
		--infobox "Choose the directory that your torrent tool will pick up torrent files to begin downloading" 7 80 \
		--and-widget \
			--begin 20 50 \
			--dselect ~/Downloads 20 60 2>output.txt
	DOWNDIR=$(cat output.txt)
	rm output.txt
	
	set_setting "DownloadDir" "$DOWNDIR"
fi


# before we do too much more, we need to get the latest Torrent ID.  This will also ensure that the site is working as expected.
# Note that when background tasks start, we will pass in the ID from the site to save having to look it up again.

LATEST_ITEM_ID=$(query "SELECT ItemID FROM Items ORDER BY ItemID DESC LIMIT 1;")
if [ -z "$LATEST_ITEM_ID" ]; then
	LATEST_ITEM_ID=0
fi

dialog --infobox "Getting the latest ID from the Site" 4 60
LATEST_ID=$(get_latest_id)
if [ "$LATEST_ID" -le 0 ]; then
	dialog --infobox "Something is wrong.  Latest ID didn't return expected results" 5 60
	sleep 5
	exit 1
fi

# now we are pretty sure that the site is working.
# will now kick off the background process which will cycle through tasks that need to be done.
# the fore-ground process (interface to the user) will then continue.

# Any Item that doesn't have a specific 'Download' value set, should be set.
# (This is because original script didn't set that value)
query "UPDATE Items SET Download=0 WHERE Download IS NULL"
	



# We will use a flag in the database to tell the Background Tasks Process to stop.  So lets clear that first.
# Note that if we set TESTMODE, then it will limit it to only one background cycle.
query "UPDATE Config SET ProcessingStop=$TESTMODE;"
TOPROC=$(query "SELECT COUNT(*) FROM Items WHERE Status=1 AND Download=0 AND Seeders>0")

echo "-----------------------------------------------">>process.log
date>>process.log
echo "Latest ID (Database): $LATEST_ITEM_ID">>process.log
echo "Latest ID (Site): $LATEST_ID">>process.log
echo "Items left to process: $TOPROC">>process.log
echo "Starting Background Tasks">>process.log


process_tasks $LATEST_ID >> process.log &
TASKS_PID=$!
if [ $TASKS_PID -eq 0 ]; then
	dialog --infobox  "Something went wrong when starting the background process." 5 50
	sleep 5
	exit 1
fi

######

main_menu

# --print-maxsize

dialog --infobox "Waiting for Background tasks to complete" 5 50


query "UPDATE Config SET ProcessingStop=1;"
wait $TASKS_PID

echo "Main Script Stopped.">>process.log
clear
