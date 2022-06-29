#!/usr/bin/env bash
version=1.0.16
usage() {
  usage="  Usage: $basename [OPTIONS]

DESCRIPTION
  Arno is a based script for automatize installation

OPTIONS
  General options
    -h,--help,help
    -l,--list
    -v,--version
    -f,--force-update"
  printf "$usage\n"
}

# ANSI Colors
load_ansi_colors() {
  # @C FG Color
  #    |-- foreground color
  export CReset=$'\e[m' CFGBlack='\e[30m' CFGRed='\e[31m' CFGGreen='\e[32m' \
    CFGYellow='\e[33m' CFGBlue='\e[34m' CFGPurple='\e[35m' CFGCyan='\e[36m' \
    CFGWhite='\e[37m'
  # @C BG Color
  #    |-- background color
  export CBGBlack='\e[40m' CBGRed='\e[41m' CBGGreen='\e[42m' CBGYellow='\e[43m' \
    CBGBlue='\e[44m' CBGPurple='\e[45m' CBGCyan='\e[46m' CBGWhite='\e[47m'
  # @C Attribute
  #    |-- text attribute
  export CBold='\e[1m' CFaint='\e[2m' CItalic='\e[3m' CUnderline='\e[4m' \
    CSBlink='\e[5m' CFBlink='\e[6m' CReverse='\e[7m' CConceal='\e[8m' \
    CCrossed='\e[9m' CDoubleUnderline='\e[21m'
}

debug() {
  if [ -x "$APP_DEBUG" ] && $APP_DEBUG ||
     [[ ${APP_DEBUG,,} == @(true|1|on) ]]; then
    echo -e "<!--\n [+] $(cat -A <<< "$*")\n-->"
  fi
}

in_array() {
  local needle=$1 haystack
  printf -v haystack '%s|' "${@:2}"
  [[ "$needle" == @(${haystack%|}) ]]
}

print_message() {
  if [[ $* ]]; then
    message_fmt="\n\n${CBold}${CFGCyan}〔${CFGWhite}✓${CFGCyan}〕%s${CReset}\n"
    printf "$message_fmt" "$*"
  fi
}

lolcat() {
  lolcat=/usr/games/lolcat
  if type -t $lolcat >/dev/null; then $lolcat; else cat; fi <<< "$1"
}

banner() {
  lolcat "
   █████████   ███████████   ██████   █████    ███████ ®
  ███░░░░░███ ░░███░░░░░███ ░░██████ ░░███   ███░░░░░███
 ░███    ░███  ░███    ░███  ░███░███ ░███  ███     ░░███
 ░███████████  ░██████████   ░███░░███░███ ░███      ░███
 ░███░░░░░███  ░███░░░░░███  ░███ ░░██████ ░███      ░███
 ░███    ░███  ░███    ░███  ░███  ░░█████ ░░███     ███
 █████   █████ █████   █████ █████  ░░█████ ░░░███████░
░░░░░   ░░░░░ ░░░░░   ░░░░░ ░░░░░    ░░░░░    ░░░░░░░
                                       ➥ version: $version

            A Reconaissance Tool's Collection.

📥 Discord Community

 〔https://discord.io/thekrakenhacker〕
🛠  Recode The Copyright Is Not Make You A Coder Dude
"
}

system_update() {
  if [[ ! $is_updated ]]; then
    apt update && is_updated=1
  fi
}
export -f system_update

system_upgrade() {
  print_message 'Updating system'
  apt -y upgrade <<< 'SYSTEM_UPGRADE'
  apt -y autoremove
  apt -y autoclean
}

check_dependencies() {
  git_install 'https://github.com/DonatoReis/Kraken' 'kraken.sh'
  (
    srcdir="$srcdir/NRZCode/Kraken/vendor"
    git_install 'https://github.com/NRZCode/progressbar'
    git_install 'https://github.com/NRZCode/bash-ini-parser'
  )
  source "$workdir/vendor/NRZCode/bash-ini-parser/bash-ini-parser"
}

check_inifile() {
  if [[ ! -r "$inifile" ]]; then
    [[ -r "$workdir/package-dist.ini" ]] &&
      cp "$workdir"/package{-dist,}.ini ||
      wget -qO "$workdir/package.ini" https://github.com/DonatoReis/Kraken/raw/master/package-dist.ini
  fi
  [[ -r "$inifile" ]] || exit 1
}

init_install() {
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p "$srcdir"
  system_update
  if [[ $force_update == 1 ]]; then
    apt -f install
    apt --fix-broken install -y
    dpkg --configure -a
    rm -f $HOME/.local/._first_install.lock
  fi
  # REQUIREMENTS
  print_message 'Complete tool to install and configure various tools for pentesting.'
  printf "\n${CBold}${CFGWhite}◖»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»${CReset}\n\n"
  if [[ ! -f $HOME/.local/._first_install.lock ]]; then
    packages='python3-pip apt-transport-https curl libcurl4-openssl-dev libssl-dev jq ruby-full libcurl4-openssl-dev ruby libxml2 libxml2-dev libxslt1-dev ruby-dev dkms build-essential libgmp-dev hcxdumptool zlib1g-dev perl zsh fonts-powerline libio-socket-ssl-perl libdbd-sqlite3-perl libclass-dbi-perl libio-all-lwp-perl libparallel-forkmanager-perl libredis-perl libalgorithm-combinatorics-perl gem git cvs subversion bzr mercurial libssl-dev libffi-dev python-dev-is-python3 ruby-ffi-yajl python-setuptools libldns-dev rename docker.io parsero apache2 ssh tor privoxy proxychains4 aptitude synaptic lolcat yad dialog golang-go graphviz virtualenv reaver bats openssl cargo cmake'
    wget -O /tmp/go1.18.3.linux-amd64.tar.gz https://go.dev/dl/go1.18.3.linux-amd64.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go1.18.3.linux-amd64.tar.gz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    case $distro in
      Ubuntu)
        packages+=' chromium-browser whois'
        ;;
      Kali)
        apt -y install kali-desktop-gnome
        packages+=' hcxtools amass joomscan uniscan metagoofil gospider crackmapexec arjun dnsgen s3scanner chromium libwacom-common'
        ;;
    esac
    apt -y install $packages
    system_upgrade
    pip3 install --upgrade pip osrframework py-altdns==1.0.2 requests wfuzz holehe twint droopescan uro arjun dnsgen s3scanner emailfinder pipx one-lin3r win_unicode_console aiodnsbrute webscreenshot dnspython netaddr git-dumper
    gem install typhoeus opt_parse_validator blunder wpscan
    cargo install ppfuzz
    mkdir -p "$HOME/.local"
    > $HOME/.local/._first_install.lock
  fi
}

get_distro() {
  if type -t lsb_release &>/dev/bull; then
    distro=$(lsb_release -is)
  elif [[ -f /etc/os-release || \
          -f /usr/lib/os-release || \
          -f /etc/openwrt_release || \
          -f /etc/lsb-release ]]; then
    for file in /usr/lib/os-release  /etc/{os-,openwrt_,lsb-}release; do
      source "$file" && break
    done
    distro="${NAME:-${DISTRIB_ID}} ${VERSION_ID:-${DISTRIB_RELEASE}}"
  fi
}

progressbar() {
  local progressbar="$workdir/vendor/NRZCode/progressbar/ProgressBar.sh"
  [[ -x "$progressbar" && -z $APP_DEBUG ]] && $progressbar "$@" || cat
}

cfg_listsections() {
  local file=$1
  grep -oP '(?<=^\[)[^]]+' "$file"
}

read_package_ini() {
  local sec url script post_install
  cfg_parser "$inifile"
  while read sec; do
    unset url script depends post_install
    cfg_section_$sec 2>&-
    tools[${sec,,}]="$url|$script|$depends|$post_install"
  done < <(cfg_listsections "$inifile")
}

git_install() {
  local repo=${1%%+(.git|/)}
  local app=$2
  local cmd=$3
  if [[ $repo ]]; then
    : "${repo%/*}"
    local vendor=${_##*/}
    export installdir="$srcdir/$vendor/${repo##*/}"
    if [[ -d "$installdir/.git" ]]; then
      git -C "$installdir" pull $GIT_OPT --all
    elif [[ ! -d "$installdir" ]]; then
      git clone $GIT_OPT "$repo" "$installdir"
    fi | progressbar -s normal -m "${repo##*/}: Cloning repository"
    if [[ $app ]]; then
      [[ -f "$installdir/$app" ]] && chmod +x "$installdir/$app"
      bin="$bindir/${app##*/}"
      ln -sf "$installdir/$app" "$bin"
      ln -sf "$installdir/$app" "${bin%.*}"
    fi
    if [[ -r "$installdir/requirements.txt" ]]; then
      result=$(cd "$installdir";pip3 install -q -r requirements.txt 2>>$logerr >>$logfile) | progressbar -s fast -m "${repo##*/}: Python requirements"
    fi
    if [[ -r "$installdir/setup.py" ]]; then
      result=$(cd "$installdir";python3 setup.py -q install 2>>$logerr >>$logfile) | progressbar -s fast -m "${repo##*/}: Installing setup.py"
    fi
  fi
}

checklist_report() {
  CFGBRed=$'\e[91m'
  CFGBGreen=$'\e[92m'
  if [[ $check_mode == 1 ]]; then
    print_message 'Checklist from package.ini'
    for tool in ${!tools[*]}; do
      IFS='|' read url script depends post_install <<< "${tools[$tool]}"
      if [[ $url || $post_install ]]; then
        [[ "$depends$script" ]] || printf '[%s]\nscript=%s\ndepends=%s\n%s: \e[33mWARNING\e[m: is not possible verify installation: depends is not defined\n\n\n' "$tool" "$script" "$depends" "$tool"
      fi
    done
  fi
  print_message 'Checklist report from tools install'
  for tool in ${selection,,}; do
    tool_list=${!tools[*]}
    if in_array "$tool" ${tool_list,,}; then
      IFS='|' read url script depends post_install <<< "${tools[$tool]}"
      if [[ $depends || $script ]]; then
        status=$'Fail'
        if type -t $depends ${script##*/} >/dev/null; then
          status='Ok'
        fi
        echo "${tool^} [$status]"
      fi
    fi
  done | column | sed "s/\[Ok\]/[${CFGBGreen}Ok${CReset}]/g;s/\[Fail\]/[${CFGBRed}Fail${CReset}]/g"
}

shopt -s extglob
dirname=${BASH_SOURCE%/*}
basename=${0##*/}

export srcdir=${srcdir:-/usr/local}
export bindir=${bindir:-$srcdir/bin}
export GOBIN=$bindir GOPATH=$bindir
workdir="$srcdir/NRZCode/Kraken"
logfile="$workdir/${basename%.*}.log"
logerr="$workdir/${basename%.*}.err"
inifile="$workdir/package.ini"
GIT_OPT='-q'
[[ $APP_DEBUG ]] && GIT_OPT=

banner
load_ansi_colors
while [[ $1 ]]; do
  case $1 in
    -h|--help|help)
      usage
      exit 0
      ;;
    -v|--version)
      echo $version
      exit 0
      ;;
    -f|--force-update)
      force_update=1
      shift
      ;;
    -l|--list)
      [[ -f "$inifile" ]] && pkgs=$(grep -oP '(?<=^\[)[^]]+' $inifile)
      echo "  Uso: ./$basename" $pkgs
      exit 0
      ;;
    -c|--check)
      check_mode=1
      shift
      ;;
    *)
      packages+=($1)
      shift
      ;;
  esac
done
if [[ 0 != $EUID ]]; then
  printf 'Must run as root!!!\n$ sudo ./%s\n' "$basename"
  exit 1
fi

get_distro
check_dependencies
declare -A tools
check_inifile
read_package_ini

selection="${packages[*]}"
if [[ ${#packages[@]} == 0 ]]; then
  selection="${!tools[*]}"
fi

[[ $check_mode == 1 ]] && { checklist_report; exit; }

init_install
for tool in ${selection,,}; do
  tool_list=${!tools[*]}
  if in_array "$tool" ${tool_list,,}; then
    export url script
    IFS='|' read url script depends post_install <<< "${tools[$tool]}"
    if [[ $url || $post_install ]]; then
      print_message "Installing ${tool^}"
      [[ $url ]] && git_install "$url" "$script"
      [[ $post_install ]] && {
        result=$(bash -c "$post_install" 2>>$logerr >>$logfile) | progressbar -s normal -m "${tool^}: Installation"
      }
    fi
  fi
done
checklist_report
