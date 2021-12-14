#!/usr/bin/env bash
# Script to build, deploy and run Sakai in docker containers
# TODO Provide option for cleaning up these instances

# Set up some options, TODO make these configurable (pull from the environment if it's set)

# Whether or not to set wicket debug mode on
# This should either be development or deployment
WICKET_CONFIG="development"

# Number of threads, might need to change this for debuggging
THREADS=C1

cd $(dirname "${0}") > /dev/null
BASEDIR=$(pwd -L)
cd - > /dev/null

WORK="${BASEDIR}/work"
# Where tomcat files will be
TOMCAT="${WORK}/tomcat"
# Where files will be deployed
DEPLOY="${TOMCAT}/deploy"
# Sakai home filse
SAKAIHOME="${TOMCAT}/sakaihome"

# Which maven image to use
MAVEN_IMAGE="markhobson/maven-chrome:jdk-8"

# This defaults to detroit timezone. Make this configurable
TIMEZONE="America/New_York"

printf "WORK:$WORK\nTOMCAT:$TOMCAT\nDEPLOY:$DEPLOY\nWICKET_CONFIG:$WICKET_CONFIG\n"

# Opts from SAK-33595 indicated for JDK11
JDK11_OPTS="--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED --add-exports=java.base/sun.nio.ch=ALL-UNNAMED --add-exports=java.management/com.sun.jmx.mbeanserver=ALL-UNNAMED --add-exports=jdk.internal.jvmstat/sun.jvmstat.monitor=ALL-UNNAMED --add-exports=java.base/sun.reflect.generics.reflectiveObjects=ALL-UNNAMED --add-opens jdk.management/com.sun.management.internal=ALL-UNNAMED --illegal-access=permit"

# This may be reconfigured
JDK11_GC="-Xlog:gc"

start_tomcat() {
    CONTAINER_NAME="sakai-21-tomcat"
    CONTAINER_ID=$(docker inspect --format="{{.Id}}" ${CONTAINER_NAME} 2> /dev/null)

    if [[ "${CONTAINER_ID}" ]]; then
        echo "${CONTAINER_NAME} exists, removing previous instance"
    	docker stop ${CONTAINER_NAME} > /dev/null && docker rm ${CONTAINER_NAME} > /dev/null
    fi

	# docker network create ${CONTAINER_NAME}
	docker run -d --name=${CONTAINER_NAME} --pull always \
	    -p 8080:8080 -p 8089:8089 -p 8000:8000 -p 8025:8025 \
	    -e "CATALINA_BASE=/usr/src/app/deploy" \
	    -e "CATALINA_TMPDIR=/tmp" \
	    -e "JAVA_OPTS=-server -d64 -Xms1g -Xmx2g -Djava.awt.headless=true -XX:+UseCompressedOops -XX:+UseConcMarkSweepGC -XX:+DisableExplicitGC -Dhttp.agent=Sakai -Dorg.apache.jasper.compiler.Parser.STRICT_QUOTE_ESCAPING=false” -Dsakai.home=/usr/src/app/deploy/sakai/ -Duser.timezone=${TIMEZONE} -Dsakai.cookieName=SAKAI2SESSIONID -Dsakai.demo=true -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=8089 -Dcom.sun.management.jmxremote.local.only=false -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false -Dwicket.configuration=${WICKET_CONFIG}" \
		-e "JPDA_ADDRESS=8000" \
		-e "VIRTUAL_HOST=sakai-21.localhost" \
		-e "VIRTUAL_PORT=8080" \
	    -v "${DEPLOY}:/usr/src/app/deploy:cached" \
	    -v "${SAKAIHOME}:/usr/src/app/deploy/sakai:cached" \
	    -v "${TOMCAT}/catalina_base/bin:/usr/src/app/deploy/bin:cached" \
	    -v "${TOMCAT}/catalina_base/conf:/usr/src/app/deploy/conf:cached" \
	    -v "${TOMCAT}/catalina_base/webapps/ROOT:/usr/src/app/deploy/webapps/ROOT:cached" \
	    -u `id -u`:`id -g` \
	    --link sakai-21-mariadb \
	    tomcat:9-jdk8-openjdk \
	    /usr/local/tomcat/bin/catalina.sh jpda run || docker start ${CONTAINER_NAME}

	docker network connect nginxproxy_default ${CONTAINER_NAME}
}

start_mariadb() {
	mkdir -p "${WORK}/mysql/data"
    CONTAINER_NAME="sakai-21-mariadb"
    CONTAINER_ID=$(docker inspect --format="{{.Id}}" ${CONTAINER_NAME} 2> /dev/null)

    if [[ "${CONTAINER_ID}" ]]; then
        echo "${CONTAINER_NAME} exists, removing previous instance"
    	docker stop ${CONTAINER_NAME} > /dev/null && docker rm ${CONTAINER_NAME} > /dev/null
    fi
	# May want to include an opt for docker rm sakai-mariadb
	# Start it if we've already created it, unless we want to re-create
	docker run -p 127.0.0.1:53306:3306 -d --name=${CONTAINER_NAME} --pull always \
	    -e "MARIADB_ROOT_PASSWORD=sakairoot" \
	    -v "${WORK}/mysql/scripts:/docker-entrypoint-initdb.d:delegated" \
	    -v "${WORK}/mysql/data:/var/lib/mysql:delegated" \
	    -u `id -u`:`id -g` \
	    -d mariadb:10 --lower-case-table-names=1 || docker start ${CONTAINER_NAME}
}

# This is mostly for debugging maven/tomcat
start_bash() {
	docker run --rm -it \
	    -v "${DEPLOY}:/usr/src/deploy" \
	    -v "${WORK}/.m2:/tmp/.m2" \
	    -v "${WORK}/.npm:/.npm" \
	    -v "${WORK}/.config:/.config" \
	    -v "${WORK}/.cache:/.cache" \
	    -v "${PWD}:/usr/src/app" \
	    bash:4.4
}

maven_build() {
	echo $@
	# If docker creates this directory it does it as the wrong user, so create it first
	# These are on the host so they can be re-used between builds
	mkdir -p "$DEPLOY/lib"
	mkdir -p "$WORK/.m2"
	mkdir -p "$WORK/.npm"
	mkdir -p "$WORK/.config"
	mkdir -p "$WORK/.cache"

	# Copy the p6spy files into the lib directory
	cp ${BASEDIR}/p6spy/p6spy-3.9.1.jar ${BASEDIR}/p6spy/spy.properties ${DEPLOY}/lib

	# Now build the code
	docker run --rm -it --pull always --name sakai-build-21 \
	    -e "MAVEN_OPTS=-XX:+TieredCompilation -XX:TieredStopAtLevel=1" \
	    -e "MAVEN_CONFIG=/tmp/.m2" \
	    -v "${DEPLOY}:/usr/src/deploy:delegated" \
	    -v "${WORK}/.m2:/tmp/.m2:delegated" \
	    -v "${WORK}/.npm:/.npm:delegated" \
	    -v "${WORK}/.config:/.config:delegated" \
	    -v "${WORK}/.cache:/.cache:delegated" \
	    -v "${PWD}:/usr/src/app:cached" \
	    -u `id -u`:`id -g` \
		--cap-add=SYS_ADMIN \
	    -w /usr/src/app ${MAVEN_IMAGE} \
	    /bin/bash -c "mvn -T ${THREADS} -B ${UPDATES} clean install ${SAKAI_DEPLOY} ${PROFILE} ${FLAG} -Dmaven.test.skip=${MAVEN_TEST_SKIP} -Djava.awt.headless=true -Dmaven.tomcat.home=/usr/src/deploy -Dsakai.cleanup=true -Duser.home=/tmp/"
}

build_skins() {
	# SKIN="duke-default"
	# FLAG="-Dsakai.skin.customization.file=./src/morpheus-master/sass/_$SKIN.scss -Dsakai.skin.overrides.file=./src/morpheus-master/sass/_$SKIN-overrides.scss -Dsakai.skin.customization.js.lib=duke-lib.js -Dsakai.skin.customization.js.main=$SKIN.js -Dsakai.skin.target=$SKIN"
	# maven_build

	SKINS=( "duke-default" "duke-extend" "duke-alumni" "duke-crtp" "duke-dghi" "duke-divinity" "duke-dku" "duke-law" "duke-nursing" "duke-pratt" "duke-samsi" )
	i=0;
	while [ $i -lt ${#SKINS[*]} ]; do
		FLAG="-Dsakai.skin.customization.file=./src/morpheus-master/sass/_${SKINS[$i]}.scss -Dsakai.skin.overrides.file=./src/morpheus-master/sass/_${SKINS[$i]}-overrides.scss -Dsakai.skin.customization.js.lib=duke-lib.js -Dsakai.skin.customization.js.main=${SKINS[$i]}.js -Dsakai.skin.target=${SKINS[$i]}"
		maven_build
		i=$(( i + 1));
	done
}
clean_deploy() {
	rm -rf $DEPLOY
}

clean_data() {
	rm -rf ${WORK}/mysql/data
	rm -rf ${SAKAIHOME}/samigo
	rm -rf ${SAKAIHOME}/ignite
}

kill_all() {
	docker kill sakai-21-tomcat sakai-21-mariadb
	docker rm sakai-21-tomcat sakai-21-mariadb
}

# Turn off command echo
set +x

# Defaults
SAKAI_DEPLOY="sakai:deploy-exploded"
MAVEN_TEST_SKIP=true

COMMAND=$1; shift

while getopts "tdUcPD" option; do
    case "${option}" in
    t) MAVEN_TEST_SKIP=false;;
    d) SAKAI_DEPLOY="";;
    U) UPDATES="-U";;
    c) MAVEN_IMAGE="sakai:build";;
    P) PROFILE="-P$2";;
	D) FLAG="-Dsakai.skin.customization.file=./src/morpheus-master/sass/_$2.scss -Dsakai.skin.overrides.file=./src/morpheus-master/sass/_$2-overrides.scss -Dsakai.skin.customization.js.lib=duke-lib.js -Dsakai.skin.customization.js.main=$2.js -Dsakai.skin.target=$2";;
	*) echo "Incorrect options provided"; exit 1;;
    esac
done

#TODO Add some of these options (deploy, test skip, etc) as options

case "$COMMAND" in
    tomcat)
	    start_tomcat;;
    mysql)
    	start_mariadb;;
    mariadb)
        start_mariadb;;
    build)
    	maven_build;;
	build_skins)
		build_skins;;
    clean_deploy)
    	clean_deploy;;
    clean_data)
    	clean_data;;
    bash)
		start_bash;;
    kill)
    	kill_all;;
    *)  
        echo "
        Usage $0
        mysql or mariadb (Starts MariaDB)
        tomcat (Starts tomcat)
        build (Build and deploy sakai tool to tomcat)
            By Default tests are skipped AND the artifacts are deployed
            ** Add options after (just currently for build) 
            -t (Don't skip tests)
            -d (Don't deploy to tomcat)
	    -U (Force updates)
	    -c (Use custom maven image)
        kill (Stop all instances) 
        clean_deploy (Clean the deploy directory)
        clean_data (Clean the database directory)
        bash (Starts a debugging shell"
        exit 1
esac	
