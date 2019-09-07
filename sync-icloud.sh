#!/bin/ash

##### Functions #####
CheckTerminal(){
   if [ -t 0 ]; then
      INTERACTIVE=True
   else
      INTERACTIVE=False
   fi
}

CookieName(){
   COOKIE="${APPLEID//_/}"
   COOKIE="${COOKIE// /_}"
   COOKIE="${COOKIE//[^a-zA-Z0-9_]/}"
   COOKIE="$(echo -n "${COOKIE}" | tr A-Z a-z)"
}

CheckVariables(){
   if [ -z "${USER}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  User name not set, defaulting to 'user'"; USER="user"; fi
   if [ -z "${UID}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  User ID not set, defaulting to '1000'"; UID="1000"; fi
   if [ -z "${GROUP}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Group name not set, defaulting to 'group'"; GROUP="group"; fi
   if [ -z "${GID}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Group ID not set, defaulting to '1000'"; GID="1000"; fi
   if [ -z "${INTERVAL}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Syncronisation interval not set, defaulting to 86400 seconds (1 day) "; INTERVAL="86400"; fi
   if [ -z "${NOTIFICATIONDAYS}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Notification period not set, defaulting to 7 days"; NOTIFICATIONPERIOD="7"; fi
   if [ -z "${TZ}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Time zone not set, defaulting to Coordinated Universal Time 'UTC'"; export TZ="UTC"; fi
   if [ -z "${AUTHTYPE}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Authentication type not set, defaulting to two factor authentication"; AUTHTYPE="2FA"; fi
   if [ "${NOTIFICATIONTYPE}" = "Prowl" ] && [ -z "${APIKEY}" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Prowl notifications enabled, but Prowl API key not set - disabling notifications"
      unset "${NOTIFICATIONTYPE}"
   elif [ "${NOTIFICATIONTYPE}" = "Prowl" ] && [ ! -z "${APIKEY}" ]; then
      NOTIFICATIONURL="https://api.prowlapp.com/publicapi/add"
      NEXTNOTIFICATION="$(date +%s)"
   fi
   if [ "${NOTIFICATIONTYPE}" = "Pushbullet" ] && [ -z "${APIKEY}" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Pushbullet notifications enabled, but Pushbullet API key not set - disabling notifications"
      unset "${NOTIFICATIONTYPE}"
   elif [ "${NOTIFICATIONTYPE}" = "Pushbullet" ] && [ ! -z "${APIKEY}" ]; then
      NOTIFICATIONURL="https://Pushbullet.weks.net/publicapi/add"
      NEXTNOTIFICATION="$(date +%s)"
   fi
   if [ -z "${APPLEPASSWORD}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR    Apple ID Password not set - exiting"; exit 1; fi
   if [ -z "${APPLEID}" ]; then echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR    Apple ID not set - exiting"; exit 1; fi
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Local user: ${USER}:${UID}"
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Local group: ${GROUP}:${GID}"
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Apple ID: ${APPLEID}"
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Apple ID Password: ${APPLEPASSWORD}"
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Cookie directory: ${CONFIGDIR}"
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     iCloud directory: /home/${USER}/iCloud"
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Command line options: ${CLIOPTIONS}"
}

CreateGroup(){
   if [ -z "$(getent group ${GROUP} | cut -d: -f3)" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Group ID available, creating group"
      addgroup -g "${GID}" "${GROUP}"
   elif [ ! "$(getent group "${GROUP}" | cut -d: -f3)" = "${GID}" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR    Group ID already in use - exiting"
      exit 1
   fi
}

CreateUser(){
   if [ -z "$(getent passwd "${USER}" | cut -d: -f3)" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     User ID available, creating user"
      adduser -s /bin/ash -D -G "${GROUP}" -u "${UID}" "${USER}" -h "/home/$USER"
   elif [ ! "$(getent passwd "${USER}" | cut -d: -f3)" = "${UID}" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR    User ID already in use - exiting"
      exit 1
   fi
}

Generate2FACookie(){
   if [ -f "${CONFIGDIR}/${COOKIE}" ]; then
      rm "${CONFIGDIR}/${COOKIE}"
   fi
   su "${USER}" -c "/usr/bin/icloudpd --username \"${APPLEID}\" --password \"${APPLEPASSWORD}\" --cookie-directory \"${CONFIGDIR}\""
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Two factor authentication cookie generated. Sync should now be successful"
   exit 0
}

CheckMount(){
   while [ ! -f "/home/${USER}/iCloud/.mounted" ]; do
      echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR    Destination volume not mounted - retry in 5 minutes"
      sleep 300
   done
}

SetOwnerAndGroup(){
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Set group and permissions of downloaded files..."
   find "/home/${USER}/iCloud" ! -user "${USER}" -exec chown "${USER}" {} \;
   find "/home/${USER}/iCloud" ! -group "${GROUP}" -exec chgrp "${GROUP}" {} \;
   find "/home/${USER}/iCloud" -type d ! -perm 770 -exec chmod 770 {} +
   find "/home/${USER}/iCloud" -type f ! -perm 660 -exec chmod 660 {} +
}

Check2FACookie(){
   if [ -f "${CONFIGDIR}/${COOKIE}" ]; then
      if [ $(grep -c "X-APPLE-WEBAUTH-HSA-TRUST" "${CONFIGDIR}/${COOKIE}") -eq 1 ]; then
         EXPIRE2FA="$(grep "X-APPLE-WEBAUTH-HSA-TRUST" "${CONFIGDIR}/${COOKIE}" | sed -e 's#.*expires="\(.*\)"; HttpOnly.*#\1#')"
         EXPIRE2FA="${EXPIRE2FA::-1}"
         EXPIRE2FASECS="$(date -d "${EXPIRE2FA}" '+%s')"
         DAYSREMAINING="$(($((EXPIRE2FASECS - $(date '+%s'))) / 86400))"
         if [ "${DAYSREMAINING}" -gt 0 ]; then COOKIE2FAVALID="True"; fi
         echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Valid two factor authentication cookie found"
      else
         echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR    Cookie is not 2FA capable, authentication type may have changed. Please run container interactively to generate - Retry in 5 minutes"
         sleep 300
      fi
   else
      echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR    Cookie does not exist. Please run container interactively to generate - Retry in 5 minutes"
      sleep 300
   fi
}

SetDateTimeFromExif(){
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Set correct file time stamp from exif data..."
   exiftool -d "%Y:%m:%d %H:%M:%S" '-FileModifyDate<createdate' '-FileModifyDate<creationdate' '-filemodifydate<datetimeoriginal' -if '(($datetimeoriginal and ($datetimeoriginal ne $filemodifydate)) or ($creationdate and ($creationdate ne $filemodifydate)))' -r -q "/home/${USER}/iCloud"
}

Display2FAExpiry(){
      echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Two factor authentication cookie expires: ${EXPIRE2FA/ / @ }"
      if [ "${DAYSREMAINING}" -lt "${NOTIFICATIONPERIOD}" ]; then
         if [ "${SYNCTIME}" -gt "${NEXTNOTIFICATION}" ]; then
            if [ "${DAYSREMAINING}" -eq 1 ]; then
               echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Final day before two factor authentication cookie expires - Please reinitialise now"
               if [ "${NOTIFICATIONTYPE}" = "Prowl" ] || [ "${NOTIFICATIONTYPE}" = "Pushbullet" ]; then
                  Notify "2" "Final day before two factor authentication cookie expires - Please reinitialise now"
               fi
            else
               echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING  Only ${DAYSREMAINING} days until two factor authentication cookie expires - Please reinitialise"
               if [ "${NOTIFICATIONTYPE}" = "Prowl" ] || [ "${NOTIFICATIONTYPE}" = "Pushbullet" ]; then
                  Notify "1" "Only ${DAYSREMAINING} days until two factor authentication cookie expires - Please reinitialise"
               fi
            fi
         fi
      fi
}

Notify(){
   curl "${NOTIFICATIONURL}"  \
      -F apikey="${APIKEY}" \
      -F application="$(date)" \
      -F event="iCloud Photo Downloader" \
      -F priority="${1}" \
      -F description="${2}" \
      >/dev/null 2>&1 &
   echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Prowl notification sent - ${2}"
   NEXTNOTIFICATION=$(date +%s -d "+24 hour")
}

SyncUser(){
   while :; do
      if [ "${AUTHTYPE}" = "2FA" ]; then
         COOKIE2FAVALID=False
         while [ "${COOKIE2FAVALID}" = "False" ]; do Check2FACookie; done
      fi
      echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Syncronisation started for ${USER}"
      SYNCTIME="$(date +%s -d '+15 minutes')"
      CheckMount
      su -s /bin/ash "${USER}" -c "/usr/bin/icloudpd --directory /home/${USER}/iCloud --cookie-directory ${CONFIGDIR} --username ${APPLEID} --password \"${APPLEPASSWORD}\" ${CLIOPTIONS}"
      if [ $? -ne 0 ]; then
         echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR    Exit code non-zero - Error: $?"
      fi
      if [ "${SETDATETIMEEXIF}" = "True" ]; then SetDateTimeFromExif; fi
      SetOwnerAndGroup
      if [ "${AUTHTYPE}" = "2FA" ]; then Display2FAExpiry; fi
      echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Syncronisation complete for ${USER}"
      echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     Next syncronisation at $(date +%H:%M -d "${INTERVAL} seconds")"
      sleep "${INTERVAL}"
   done
}

##### Script #####
echo "$(date '+%Y-%m-%d %H:%M:%S') INFO     ***** iCoud_photo_downloader container started *****"
CheckTerminal
CookieName
CheckVariables
CreateGroup
CreateUser
if [ "${INTERACTIVE}" = "True" ]; then Generate2FACookie; fi
CheckMount
SetOwnerAndGroup
SyncUser