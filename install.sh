#!/usr/bin/env bash
version=1.0.6
usage() {
  printf 'MSG\n'
}

# ANSI Colors
load_ansi_colors() {
  # @C FG Color
  #    |-- foreground color
  export CReset='\e[m' CFGBlack='\e[30m' CFGRed='\e[31m' CFGGreen='\e[32m' \
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
    message_fmt="\n\n${CBold}${CFGCyan}[${CFGWhite}+${CFGCyan}] %s${CReset}\n"
    printf "$message_fmt" "$*"
  fi
}

banner_color() {
  local colors logo_print
  local c=({30..37})
  logo_print="$(sed -E 's/$/\\e[m/;s/^.{26}/&\\e[%sm/;s/^.{16}/&\\e[%sm/;s/^.{8}/&\\e[%sm/;s/^/\\e[%sm/' <<< "$logo")"
  substr=$(for i in {1..4}; do echo -n "${c[$((RANDOM%${#c[@]}))]} "; done)
  printf -v colors '%6s'
  colors=(${colors// /$substr})
  printf "$logo_print\n" "${colors[@]}"
}

banner() {
  logo=' █████╗ ██████╗ ███╗   ██╗ ██████╗
██╔══██╗██╔══██╗████╗  ██║██╔═══██╗
███████║██████╔╝██╔██╗ ██║██║   ██║
██╔══██║██╔══██╗██║╚██╗██║██║   ██║
██║  ██║██║  ██║██║ ╚████║╚██████╔╝
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝'
  social="   A Reconaissance Tool's Collection.

╔════════════════════════════════════╗
║                                    ║
║ https://t.me/PeakyBlindersW        ║
║                                    ║
║ https://github.com/DonatoReis/arno ║
║                                    ║
║      Discord Community             ║
║ https://discord.gg/Z2C2CyVZFU      ║
╚════════════════════════════════════╝
                              version: $version

Recode The Copyright Is Not Make You A Coder Dude"
  [[ -x /usr/games/lolcat ]] &&
    /usr/games/lolcat <(printf "$logo\n$social\n") ||
    { banner_color "$logo"; echo "$social"; }
}

system_update() {
  if [[ ! $is_updated ]]; then
    apt update && is_updated=1
  fi
}
export -f system_update

system_upgrade() {
  print_message 'Updating system'
  apt -y full-upgrade
  sudo $SUDO_OPT pip3 install --upgrade pip
  sudo $SUDO_OPT pip3 install --upgrade osrframework
  apt -y autoremove
}

check_dependencies() {
  git_install 'https://github.com/NRZCode/GhostRecon' 'ghostrecon.sh'
  (
    srcdir="$srcdir/NRZCode/GhostRecon/vendor"
    git_install 'https://github.com/NRZCode/progressbar'
    git_install 'https://github.com/NRZCode/bash-ini-parser'
  )
  source "$workdir/vendor/NRZCode/bash-ini-parser/bash-ini-parser"
}

check_inifile() {
  if [[ ! -r "$inifile" ]]; then
    [[ -r "$workdir/package-dist.ini" ]] &&
      cp "$workdir"/package{-dist,}.ini ||
      wget -qO "$workdir/package.ini" https://github.com/NRZCode/GhostRecon/raw/master/package-dist.ini
  fi
  [[ -r "$inifile" ]] || exit 1
}

init_install() {
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p "$srcdir"
  system_update
  # REQUIREMENTS
  print_message 'Ferramenta em script Bash Completa para Bug bounty ou Pentest ! Vai poupar seu Tempo na hora de configurar sua máquina para trabalhar.'
  printf "\n${CBold}${CFGWhite}=====================================================>${CReset}\n\n"
  if [[ ! -f $HOME/.local/.arno_init_install_successful ]]; then
    apt -y install python3-pip apt-transport-https curl libcurl4-openssl-dev libssl-dev virtualbox-guest-x11 jq ruby-full libcurl4-openssl-dev ruby virtualbox-guest-utils libxml2 libxml2-dev libxslt1-dev ruby-dev build-essential libgmp-dev hcxtools hcxdumptool zlib1g-dev perl chromium zsh fonts-powerline libio-socket-ssl-perl libdbd-sqlite3-perl libclass-dbi-perl libio-all-lwp-perl libparallel-forkmanager-perl libredis-perl libalgorithm-combinatorics-perl gem git cvs subversion git bzr mercurial build-essential libssl-dev libffi-dev python2-dev python2 python-dev-is-python3 ruby-ffi-yajl python-setuptools libldns-dev nmap rename docker.io parsero apache2 amass joomscan uniscan ssh tor privoxy wifite proxychains4 hashcat aptitude synaptic lolcat python3.9-venv dialog golang-go exploitdb exploitdb-papers exploitdb-bin-sploits graphviz kali-desktop-gnome virtualenv reaver bats metagoofil openssl feroxbuster
    sudo $SUDO_OPT pip3 install --upgrade pip
    sudo $SUDO_OPT pip3 install argparse osrframework py-altdns==1.0.2 requests wfuzz holehe twint bluto droopescan uro
    sudo $SUDO_OPT pip install one-lin3r bluto dnspython requests win_unicode_console colorama netaddr
    gem install typhoeus opt_parse_validator blunder wpscan
    mkdir -p "$HOME/.local"
    > $HOME/.local/.arno_init_install_successful
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
    unset url script post_install
    cfg_section_$sec 2>&-
    tools[${sec,,}]="$url|$script|$post_install"
  done < <(cfg_listsections "$inifile")
}

git_install() {
  local repo=${1%/?(.git)}
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
      result=$(cd "$installdir";sudo $SUDO_OPT pip3 install -q -r requirements.txt 2>>$logerr >>$logfile) | progressbar -s fast -m "${repo##*/}: Python requirements"
    fi
    if [[ -r "$installdir/setup.py" ]]; then
      result=$(cd "$installdir";sudo python3 setup.py -q install 2>>$logerr >>$logfile) | progressbar -s fast -m "${repo##*/}: Installing setup.py"
    fi
  fi
}

shopt -s extglob
dirname=${BASH_SOURCE%/*}
basename=${0##*/}

export srcdir=${srcdir:-/usr/local}
export bindir=${bindir:-$srcdir/bin}
export GOBIN=$bindir
workdir="$srcdir/NRZCode/GhostRecon"
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
      [[ -f "$inifile" ]] && pkgs=$(grep -oP '^\[)[^]]+' $inifile)
      echo "  Uso: ./$basename" $pkgs
      exit 0
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

check_dependencies
declare -A tools
check_inifile
read_package_ini

homedir=$HOME
if [[ $SUDO_USER ]]; then
  SUDO_OPT="-H -E -u $SUDO_USER"
  homedir=$(getent passwd $SUDO_USER|cut -d: -f6)
fi

selection="${packages[*]}"
if [[ ${#packages[@]} == 0 ]]; then
  selection="${!tools[*]}"
fi

init_install
for tool in ${selection,,}; do
  tool_list=${!tools[*]}
  if in_array "$tool" ${tool_list,,}; then
    export url script
    IFS='|' read url script post_install <<< "${tools[$tool]}"
    print_message "Installing ${tool^}"
    [[ $url ]] && git_install "$url" "$script"
    [[ $post_install ]] && {
      result=$(bash -c "$post_install" 2>>$logerr >>$logfile) | progressbar -s normal -m "${tool^}: Installation"
    }
  fi
done
system_upgrade
