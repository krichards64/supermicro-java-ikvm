#!/bin/sh
set -e
set -u

APP_CACHE_DIR=${XDG_CACHE_HOME:-/tmp}

patch_jnlp() {
    file="$1"

    Arch86Line=$(grep -n '<resources os="Linux" arch="x86_64">' "$file" | cut -d: -f1 || true)
    if [ -n "${Arch86Line:-}" ]; then
        Arch86Line=$((Arch86Line + 1))
        sed -i "${Arch86Line}i\\
   <property name=\"jnlp.packEnabled\" value=\"true\"/>\\
   <property name=\"jnlp.versionEnabled\" value=\"true\"/>" "$file"
    fi

    ArchAmdLine=$(grep -n '<resources os="Linux" arch="amd64">' "$file" | cut -d: -f1 || true)
    if [ -n "${ArchAmdLine:-}" ]; then
        ArchAmdLine=$((ArchAmdLine + 1))
        sed -i "${ArchAmdLine}i\\
   <property name=\"jnlp.packEnabled\" value=\"true\"/>\\
   <property name=\"jnlp.versionEnabled\" value=\"true\"/>" "$file"
    fi
}

get_launch_jnlp() {
    url="http://$KVM_HOST"
    temp=$(mktemp)

    if curl --fail -sk --cookie-jar "$temp" -XPOST "$url/cgi/login.cgi" \
        --data "name=$KVM_USER&pwd=$KVM_PASS&check=00" -o /dev/null; then

        curl --fail -sk --cookie "$temp" \
            --referer "$url/cgi/url_redirect.cgi?url_name=man_ikvm" \
            "$url/cgi/url_redirect.cgi?url_name=man_ikvm&url_type=jwsk"
    fi

    rm -f "$temp"
}

get_arguments() {
    sed -e '/<argument>/!d;s#.*<argument>\([^<]*\)</argument>.*#\1#' |
    sed -e "s/['\"$]//g" | sed -e 1,4d
}

get_username() {
    sed -e '/<argument>/!d' |
    sed -e '2!d;s#.*<argument>\([^<]*\)</argument>#\1#'
}

get_password() {
    sed -e '/<argument>/!d' |
    sed -e '3!d;s#.*<argument>\([^<]*\)</argument>#\1#'
}

get_app_class() {
    sed -ne 's/.*<application-desc .*main-class="\([^"]*\)".*/\1/p'
}

install_ikvm_application() {
    launch_jnlp="$1"
    destdir="$2"

    codebase=$(echo "$launch_jnlp" | sed -e '/<jnlp /!d;s/.* codebase="//;s/".*//')
    jar=$(echo "$launch_jnlp" | sed -e '/<jar /!d;s/.* href="//;s/".*//')
    linuxlibs=$(echo "$launch_jnlp" |
        sed -e '/<nativelib /!d;/linux.*x86__/!d;s/.* href="//;s/".*//' | sort -u)

    mkdir -p "$destdir"
    cd "$destdir"

    for x in $jar $linuxlibs; do
        curl -ko "$x.pack.gz" "$codebase$x.pack.gz"
        unpack200 "$x.pack.gz" "$x"
    done

    unzip -o liblinux*.jar
    rm -rf META-INF
    
    # Copy native libraries to java.library.path
    mkdir -p /config/xdg/cache
    cp -f libiKVM*.so /config/xdg/cache/ 2>/dev/null || true
}

# --- main flow ---

JNLP=$(get_launch_jnlp)
if [ -z "$JNLP" ]; then
    echo "Failed to get launch.jnlp" >&2
    exit 1
fi

# save + patch JNLP
JNLP_FILE=$(mktemp)
echo "$JNLP" > "$JNLP_FILE"
patch_jnlp "$JNLP_FILE"

# use patched version from here on
JNLP=$(cat "$JNLP_FILE")

JAR=$(find "$APP_CACHE_DIR" -name 'iKVM*.jar' 2>/dev/null | sort | tail -n1)

if [ ! -f "${JAR:-}" ]; then
    install_ikvm_application "$JNLP" "$APP_CACHE_DIR"
    JAR=$(find "$APP_CACHE_DIR" -name 'iKVM*.jar' | sort | tail -n1)

    if [ ! -f "$JAR" ]; then
        echo "Install failure" >&2
        exit 1
    fi
fi

apt update
apt install -y zip

mkdir -p /tmp/stunnel/res/

unzip -j "$JAR" res/linux/stunnel.conf -d /tmp/stunnel/res/linux/
sed -i 's/^verify = 3$/verify = 0/' /tmp/stunnel/res/linux/stunnel.conf
sed -i 's/^; output = stunnel\.log$/output = \/tmp\/stunnel\.log/' /tmp/stunnel/res/linux/stunnel.conf

unzip -j "$JAR" res/win/stunnel.conf -d /tmp/stunnel/res/win/
sed -i 's/^verify = 3$/verify = 0/' /tmp/stunnel/res/win/stunnel.conf
sed -i 's/^; output = stunnel\.log$/output = \/tmp\/stunnel\.log/' /tmp/stunnel/res/win/stunnel.conf

unzip -j "$JAR" res/mac/stunnel.conf -d /tmp/stunnel/res/mac/
sed -i 's/^verify = 3$/verify = 0/' /tmp/stunnel/res/mac/stunnel.conf
sed -i 's/^; output = stunnel\.log$/output = \/tmp\/stunnel\.log/' /tmp/stunnel/res/mac/stunnel.conf

cd /tmp/stunnel
zip -r "$JAR" .

echo "$JAR" > /etc/cont-env.d/KVM_JAR_FILE
echo "$JNLP" | get_username > /etc/cont-env.d/KVM_EPHEMERAL_USERNAME
echo "$JNLP" | get_password > /etc/cont-env.d/KVM_EPHEMERAL_PASSWORD
echo "$JNLP" | get_app_class > /etc/cont-env.d/KVM_JAR_APPCLASS
echo "$JNLP" | get_arguments > /etc/cont-env.d/KVM_LAUNCH_ARGUMENTS

rm -f "$JNLP_FILE"