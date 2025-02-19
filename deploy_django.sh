#!/bin/bash

# Generate passowrds
DBPASS=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c12`
SFTPPASS=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c12`
ROOTDIR=/var/www/

# Input site name
echo -n "Enter your site name (spaces and special symbols are not allowed):"
read SITENAME

# Check if the /var/www/$SITENAME dir exists
if [ -d "${ROOTDIR}${SITENAME}" ]; then
    echo -n "Site name already exists. Do you want to Overwrite it? "
    read overwrite


    if [[ $overwrite == "Yes" || $overwrite == "Y" || $overwrite == "y" ]]; then
        echo "removing old configuration of gunicorn and sites available"

         rm -rf "/etc/systemd/system/gunicorn_${SITENAME}.service" | true
         rm -rf "/etc/nginx/sites-available/${SITENAME}.conf" | true

    fi
    # echo "Error: directory /var/www/$SITENAME already exists"
    # exit 1
fi
# if [ -f "/etc/systemd/system/gunicorn_${SITENAME}.service" ]; then
#     # echo "Error: Gunicorn config file '/etc/systemd/system/gunicorn_${SITENAME}.service' already exists. Try using different site name or delete the Gunicorn config file"
#     # exit 1
# fi
# if [ -f "/etc/nginx/sites-available/${SITENAME}.conf" ]; then
#     # echo "Error: Nginx config file '/etc/nginx/sites-available/${SITENAME}.conf' already exists. Try using different site name or delete the Gunicorn config file"
#     # exit 1
# fi

# Input domain name
echo -n "Enter your domain name:"
read DOMAIN


while true
do
	echo "Select database server type:
	1) MySQL
	2) MariaDB
	3) PostgreSQL
	4) SQLite"
	read -p "Enter choice [1 - 4] " CHOICE
	case $CHOICE in
	1) DBPACKAGE="mysql-server"; break ;;
	2) DBPACKAGE="mariadb-server"; break ;;
	3) DBPACKAGE="postgresql postgresql-contrib"; break ;;
	4) DBPACKAGE=""; break ;;
	*) echo -e "${RED}Error...${STD}" && sleep 1
	esac
done
if [[ $DBPACKAGE == "mysql-server" || $DBPACKAGE == "mariadb-server" ]]; then
    DBCONNECTOR="mysqlclient"
    DBENGINE="django.db.backends.mysql"
    DBPORT="3306"
fi
if [[ $DBPACKAGE == "postgresql postgresql-contrib" ]]; then
    DBCONNECTOR="psycopg2-binary"
    DBENGINE="django.db.backends.postgresql_psycopg2"
    DBPORT="5432"
fi

echo -n "Enter Django app name:"
read APPNAME

# Creating the working directory
HOMEDIR=${ROOTDIR}${SITENAME}
mkdir -p /var/www/$SITENAME



# Create a new Linux user and add it to sftp group
echo "Creating user $SITENAME..."
groupadd sftp 2> /dev/null
useradd $SITENAME -m -G sftp -s "/bin/false" -d "/var/www/$SITENAME" 2> $HOMEDIR/deploy.log
if [ "$?" -ne 0 ]; then
	echo "Can't add user"
else
    echo $SFTPPASS > ./tmp
    echo $SFTPPASS >> ./tmp
    cat ./tmp | passwd $SITENAME 2>> $HOMEDIR/deploy.log
    rm ./tmp
fi

echo -n "Do you want to regenerate FTP Password? "
    read ftppassword
if [[ $ftppassword == "Yes" || $ftppassword == "Y" || $ftppassword == "y" ]]; then

    echo $SFTPPASS > ./tmp
    echo $SFTPPASS >> ./tmp
    cat ./tmp | passwd $SITENAME 2>> $HOMEDIR/deploy.log
    rm ./tmp
fi


echo "Helping with Github Deployment issues"
if [ ! -f "$HOMEDIR/.ftp-deploy-sync-state.json" ]; then

    echo > $HOMEDIR/.ftp-deploy-sync-state.json
fi

# Input domain name
echo -n "Enable Celery? (Y|N):"
read is_celery


# Install necessary dependencies and log to deploy.log
echo "Installing Nginx, Python pip, and database server..."

sudo apt-get -y update
sudo apt-get upgrade -y

sudo apt-get -y install nginx pkg-config python3-virtualenv python3-pip $DBPACKAGE libmysqlclient-dev &> $HOMEDIR/deploy.log
echo "Installing supervisor, redis..."
sudo apt install supervisor redis -y &> $HOMEDIR/deploy.log
# Setup Python virtual environment, Django, Gunicorn, and Python MySQL connector
mkdir -p $HOMEDIR/env 
echo "Trying to set up a virtual environment..."
virtualenv -p python3 $HOMEDIR/env >> $HOMEDIR/deploy.log
source $HOMEDIR/env/bin/activate
pip install gunicorn django $DBCONNECTOR >> $HOMEDIR/deploy.log
# cd ${HOMEDIR}
# django-admin startproject app .
cd ${ROOTDIR}
if [ -f "${HOMEDIR}/${APPNAME}/settings.py" ]; then
   # Add the domain to ALLOWED_HOSTS in the settings.py
    FINDTHIS="ALLOWED_HOSTS = \[\]"
    TOTHIS="ALLOWED_HOSTS = \[\'$DOMAIN\'\]"
    sed -i -e "s/$FINDTHIS/$TOTHIS/g" ${HOMEDIR}/${APPNAME}/settings.py

fi


# Create Gunicorn config file
# echo "Creating SFTP config file..."
# echo "Match Group ${SITENAME}
# ChrootDirectory %h
# PasswordAuthentication yes
# AllowTcpForwarding no
# X11Forwarding no
# ForceCommand internal-sftp
# " > /etc/ssh/sshd_config
echo "Creating SFTP config file..."
echo "download proftpd"
sudo apt-get install ftp -y
sudo apt-get install proftpd -y
# echo "Modify vsftpd.conf | uncomment #write_enable=YES"
# sudo sed -i '/write_enable=YES/s/^#//g' /etc/vsftpd.conf
# echo "Restart vsftpd service"
# sudo service vsftpd restart
# echo "Done"
echo "ServerName  $DOMAIN
ServerType         standalone
MasqueradeAddress   $DOMAIN
RequireValidShell    off
DefaultRoot         $HOMEDIR
PassivePorts       50000 51000
AllowOverwrite on  
<IfModule mod_facts.c>
    FactsAdvertise off
</IfModule>
<Directory $HOMEDIR>
Umask 022 022
AllowOverwrite on
    <Limit READ>
        DenyAll
        </Limit>

        <Limit STOR CWD MKD RMD DELE XRMD XMKD>
        AllowAll
        </Limit>
</Directory>
" > /etc/proftpd/proftpd.conf

sudo service proftpd restart
sudo /etc/init.d/proftpd start

if  [ ! -f "/etc/nginx/sites-available/$SITENAME.conf" ]; then
    # Create NGINX config file
    echo "Creating NGINX config file..."
    echo "server {
        listen 80;
        server_name $DOMAIN www.$DOMAIN;
        error_log /var/log/nginx/$SITENAME.error.log;
        access_log /var/log/nginx/$SITENAME.access.log;
        rewrite_log on;
        server_tokens off;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection '1; mode=block';

        location /static/ {
            root /var/www/$SITENAME;
        expires 30d;
            log_not_found off;
            access_log off;
        }

        location /media/ {
            root /var/www/$SITENAME;
        expires 30d;
            log_not_found off;
            access_log off;
        }

        location / {
            include proxy_params;
            proxy_pass http://unix:/run/gunicorn_$SITENAME.sock;
        }
    }" > /etc/nginx/sites-available/$SITENAME.conf
    ln -sf /etc/nginx/sites-available/$SITENAME.conf /etc/nginx/sites-enabled/$SITENAME.conf >> $HOMEDIR/deploy.log
    systemctl restart nginx

fi

if  [ ! -f "/etc/systemd/system/gunicorn_$SITENAME.service" ]; then
    # Create Gunicorn config file
    echo "Creating Gunicorn config file..."
    echo "[Unit]
    Description=gunicorn daemon
    After=network.target

    [Service]
    User=$USER
    Group=www-data
    WorkingDirectory=${HOMEDIR}
    ExecStart=$HOMEDIR/env/bin/gunicorn --access-logfile - --workers 3 --bind unix:/run/gunicorn_$SITENAME.sock $APPNAME.wsgi:application

    [Install]
    WantedBy=multi-user.target
    " > /etc/systemd/system/gunicorn_$SITENAME.service
fi
# exit from the virtual environment and restart Gunicorn
deactivate
systemctl start gunicorn_$SITENAME
systemctl enable gunicorn_$SITENAME
systemctl daemon-reload
if [[ $is_celery == "Yes" || $is_celery == "Y" || $is_celery == "y" ]]; then

    if  [ ! -f "/etc/supervisor/conf.d/celery.conf" ]; then
        echo "Creating Celery and Celery Beat"

        echo "log" >> ${HOMEDIR}/celery.log 
        echo "log" >> ${HOMEDIR}/celery_beat.log 


        echo "[program:celery]
        command=${HOMEDIR}/env/bin/celery -A $APPNAME worker -l info
        directory=${HOMEDIR}/
        user=$USER
        autostart=true
        autorestart=true  
        stdout_logfile=${HOMEDIR}/celery.log  
        redirect_stderr=true
        " > /etc/supervisor/conf.d/celery.conf

        echo "[program:celery_beat]  
        command=${HOMEDIR}/env/bin/celery -A $APPNAME beat --scheduler django -l info
        directory=${HOMEDIR}/  
        user=$USER  
        autostart=true  
        autorestart=true
        stdout_logfile=${HOMEDIR}/celery_beat.log
        redirect_stderr=true" > /etc/supervisor/conf.d/celery_beat.conf

    fi
fi

if [[ $DBPACKAGE == "mysql-server" || $DBPACKAGE == "mariadb-server" ]]; then
	# Create a database and add the necessary config lines to app/settings.py

    FINDTHIS="127.0.0.1"
    TOTHIS="0.0.0.0"
    sed -i -e "s/$FINDTHIS/$TOTHIS/g" /etc/mysql/mysql.conf.d/mysqld.cnf
    #remove this after now
    # echo > $HOMEDIR/mysql.log
    #remove
    # if [ -f "${HOMEDIR}//mysql.log" ]; then

        echo -n "Do you want to regenerate Mysql Password? "
            read mysqlpassword
        if [[ $mysqlpassword == "Yes" || $mysqlpassword == "Y" || $mysqlpassword == "y" ]]; then

            SQL="CREATE DATABASE IF NOT EXISTS $SITENAME DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
            ALTER USER '$SITENAME'@'%' IDENTIFIED BY '$DBPASS';
            GRANT ALL PRIVILEGES ON $SITENAME.* TO '$SITENAME'@'%';
            FLUSH PRIVILEGES;"
            mysql -uroot -e "$SQL"
        
        else

            SQL="CREATE DATABASE IF NOT EXISTS $SITENAME DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
            CREATE USER '$SITENAME'@'%' IDENTIFIED BY '$DBPASS';
            GRANT ALL PRIVILEGES ON $SITENAME.* TO '$SITENAME'@'%';
            FLUSH PRIVILEGES;"
            mysql -uroot -e "$SQL"

            echo > $HOMEDIR/mysql.log
        fi
fi
if [[ $DBPACKAGE == "postgresql postgresql-contrib" ]]; then
    su postgres -c "createuser -S -D -R -w $SITENAME"
    su postgres -c "psql -c \"ALTER USER $SITENAME WITH PASSWORD '$DBPASS';\""
    su postgres -c "createdb --owner $SITENAME $SITENAME"
fi
# if [[ $DBPACKAGE != "" ]]; then
#     if [ -f "${HOMEDIR}/${APPNAME}/settings.py" ]; then

#         FINDTHIS="'default': {"
#         TOTHIS="'default': {\n        'ENGINE': '$DBENGINE',\n        'NAME': '$SITENAME',\n        'USER': '$SITENAME',\n        'PASSWORD': '$DBPASS',\n        'HOST': 'localhost',\n        'PORT': '$DBPORT',\n    },\n    'SQLite': {"
#         sed -i -e "s/$FINDTHIS/$TOTHIS/g" ${HOMEDIR}/${APPNAME}/settings.py
#     fi
# fi

echo "activate Python virtual environment"
source $HOMEDIR/env/bin/activate
if [ -f "${HOMEDIR}/${APPNAME}/settings.py" ]; then
    # configure static folder
    # echo 'STATIC_ROOT = os.path.join(BASE_DIR, "static")
    # MEDIA_ROOT = os.path.join(BASE_DIR, "media")
    # MEDIA_URL = "/media/"' >> ${HOMEDIR}/${APPNAME}/settings.py
    # mkdir -p ${HOMEDIR}/static/
    # mkdir -p ${HOMEDIR}/media/

    # # add import os to settings.py
    # sed -i '1s/^/import os\n/' ${HOMEDIR}/${APPNAME}/settings.py

    python3 manage.py migrate >> $HOMEDIR/deploy.log
    python3 manage.py collectstatic --noinput >> $HOMEDIR/deploy.log

fi


# Create .gitignore file
GIT_IGNORE="__pycache__/
db.sqlite3
migrations/
media/
env/"
echo $GIT_IGNORE > /var/www/$SITENAME/.gitignore

echo "Assigning permissions to the working directory"
chmod -R 757 /var/www/$SITENAME/
chown -R $SITENAME:$SITENAME /var/www/$SITENAME/
chown root:root /var/www/$SITENAME

if  [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    sudo snap install certbot --classic
    certbot -n -d ${DOMAIN} --nginx --agree-tos --email chijibson@gmail.com
fi
# collect static files
cd $HOMEDIR

 systemctl restart mysql
 supervisorctl reread
 supervisorctl update
 supervisorctl restart all
 nginx -t &&  systemctl restart nginx

 # Print passwords and helpers
echo "
Done!
MySQL/SFTP username: $SITENAME
MySQL password: $DBPASS
SFTP password: $SFTPPASS

Things to do:
Go to the working directory: cd $HOMEDIR
Activate virtual environment: source $HOMEDIR/env/bin/activate
Create Django super user: ./manage.py createsuperuser
Apply migrations: ./manage.py makemigrations && ./manage.py migrate
"