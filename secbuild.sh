#!/usr/bin/env bash

# Script documentation
# =======================
# This script is used to install security tools.
# To use it, run the script with the -h option to get help.

# Current script path
script_path="$(realpath "$0")"
script_name="secbuild"

# Check if the script is already in the PATH
if command -v "$script_name" >/dev/null 2>&1; then
  echo "$script_name is already in PATH." >/dev/null 2>&1
else
  # Make the script executable
  chmod +x "$script_path"

  # Move the script to /usr/local/bin and rename it
  sudo cp "$script_path" "/usr/local/bin/$script_name"
  sudo chmod +x "/usr/local/bin/$script_name"

  # Verify that the operation was successful
  if command -v "$script_name" >/dev/null 2>&1; then
    echo "$script_name has been moved to /usr/local/bin and is available in the PATH." >/dev/null 2>&1
  else
    echo "Error moving $script_name for /usr/local/bin." >/dev/null 2>&1
  fi
fi

# Folder and file path
dir_path="$HOME/.themes/CustomTheme/gtk-3.0"
file_path="$dir_path/gtk.css"
file_url="https://raw.githubusercontent.com/DonatoReis/Secbuild/master/gtk.css"

# Check if folder exists
if [ ! -d "$dir_path" ]; then
  mkdir -p "$dir_path" >/dev/null 2>&1
else
  echo "Folder $dir_path already exists." >/dev/null 2>&1
fi

echo "update secbuild."
sleep 1

# Check if the file already exists
if [ -f "$file_path" ]; then
  echo "File $file_path already exists." >/dev/null 2>&1
else
  wget -O "$file_path" "$file_url" >/dev/null 2>&1
fi

echo "configuring folders."
apt -y install yad >/dev/null 2>&1
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

  export CFGPurple=$(tput setaf 5)
  export CFGBlue=$(tput setaf 4)
}

print_message() {
  if [[ $* ]]; then
    message_fmt="\n\n${CBold}${CFGCyan}〔${CFGWhite}✓${CFGCyan}〕%s${CReset}\n"
    printf "$message_fmt" "$*"
  fi
}

lolcat() {
  lolcat=/usr/games/lolcat
  if type -t $lolcat >/dev/null; then $lolcat; else cat; fi <<<"$1"
}

banner() {
  lolcat "
${CFGBlue}███████╗███████╗ ██████╗██████╗ ██╗   ██╗██╗██╗     ██████╗ 
${CFGBlue}██╔════╝██╔════╝██╔════╝██╔══██╗██║   ██║██║██║     ██╔══██╗
${CFGBlue}███████╗█████╗  ██║     ██████╔╝██║   ██║██║██║     ██║  ██║
${CFGBlue}╚════██║██╔══╝  ██║     ██╔══██╗██║   ██║██║██║     ██║  ██║
${CFGBlue}███████║███████╗╚██████╗██████╔╝╚██████╔╝██║███████╗██████╔╝
${CFGBlue}╚══════╝╚══════╝ ╚═════╝╚═════╝  ╚═════╝ ╚═╝╚══════╝╚═════╝${CReset}
                                         ➥ version: $version

            ${CFGBlue}A Reconaissance Tool's Collection.${CReset}

📥 Discord Community - https://discord.io/thekrakenhacker

🛠  ${CFGBlue}Recode The Copyright Is Not Make You A Coder Dude${CFGPurple}
"
}

version=1.0.17a
usage() {
  usage="  Usage: $basename [-f] [-l] [tool] [-h] [OPTIONS]

OPTIONS
  General options
    -h,--help
    -l,--list
    -v,--version
    -f,--force-update

Mode display:
    secbuild

Examples:
    secbuild.sh -f
    secbuild.sh amass
"
  printf '%s\n' "$usage"
}

# Define the function to display the user interface
show_menu() {
  clear
  banner
  echo -e "\033[1;34mSecBuild - is a based script for automatize installation\033[0m"
  echo -e "--------------------------------------------------------"
  echo -e "\033[1;32m1. install   All Tools\033[0m"
  echo -e "\033[1;32m2. install   Select Tools\033[0m"
  echo -e "\033[1;32m3. check     Dependencies\033[0m"
  echo -e "\033[1;32m4. update    Update force\033[0m"
  echo -e "\033[1;32m5. help      Show help\033[0m"
  echo -e "\033[1;31m6. Sair      Exit Secbuild\033[0m"
  echo
  read -r -p "Choose an option: " user_option
  echo

  case $user_option in
    1)
      [[ $check_mode == 1 ]] && { checklist_report; exit; }
      for tool in ${selection,,}; do
        tool_list=${!tools[*]}
        if in_array "$tool" ${tool_list,,}; then
          export url script
          IFS='|' read -r url script depends post_install <<<"${tools[$tool]}"
          if [[ $url || $post_install ]]; then
            print_message "Installing ${tool^}"
            [[ $url ]] && git_install "$url" "$script"
            [[ $post_install ]] && {
              result=$(bash -c "$post_install" 2>>$logerr >>$logfile) | progressbar -s normal -m "${tool^}: Installation"
            }
          fi
        fi
      done
      show_result
      show_menu
      ;;
    2)
      declare -A categories
      categories[1]="Information gathering"
      categories[2]="Vulnerability analysis"
      categories[3]="Wireless attacks"
      categories[4]="Web applications"
      categories[5]="Sniffing spoofing"
      categories[6]="Maintaining access"
      categories[7]="Reporting tools"
      categories[8]="Exploitation tools"
      categories[9]="Forensics tools"
      categories[10]="Stress testing"
      categories[11]="Password attacks"
      categories[12]="Reverse engineering"
      categories[13]="Hardware hacking"
      categories[14]="ExtraLinux tools"
      categories[15]="Extras"

      declare -A tools
      tools[1]="acccheck ace-voip amap automater braa casefile cdpsnarf cisco-torch cookie-cadger copy-router-config dmitry dnmap dnsenum dnsmap dnsrecon dnstracer dnswalk dotdotpwn enum4linux enumiax fierce firewalk fragroute fragrouter ghost-phisher golismero goofile xplico hping3 intrace ismtp lbd maltego-teeth masscan metagoofil miranda nbtscan-unixwiz nmap p0f parsero recon-ng set smtp-user-enum snmpcheck sslcaudit sslsplit sslstrip sslyze thc-ipv6 theharvester tlssled twofi urlcrazy wireshark wol-e"
      tools[2]="bbqsql bed cisco-auditing-tool cisco-global-exploiter cisco-ocs cisco-torch copy-router-config doona dotdotpwn greenbone-security-assistant hexorbase jsql lynis nmap ohrwurm openvas-administrator openvas-cli openvas-manager openvas-scanner oscanner powerfuzzer sfuzz sidguesser siparmyknife sqlmap sqlninja sqlsus thc-ipv6 tnscmd10g unix-privesc-check yersinia"
      tools[3]="aircrack-ng asleap bluelog blueranger bluesnarfer bully cowpatty crackle eapmd5pass fern-wifi-cracker ghost-phisher giskismet gqrx hostapd-wpe kalibrate-rtl killerbee kismet mdk3 mfcuk mfoc mfterm multimon-ng pixiewps reaver redfang rtlsdr-scanner spooftooph wifi-honey wifiphisher wifitap wifite"
      tools[4]="apache-users arachni bbqsql blindelephant burpsuite cutycapt davtest deblaze dirb dirbuster fimap funkload gobuster grabber jboss-autopwn joomscan jsql maltego-teeth padbuster paros parsero plecost powerfuzzer proxystrike recon-ng skipfish sqlmap sqlninja sqlsus ua-tester uniscan vega w3af webscarab websploit wfuzz wpscan xsser zaproxy"
      tools[5]="burpsuite dnschef fiked hamster-sidejack hexinject iaxflood inviteflood ismtp isr-evilgrade mitmproxy ohrwurm protos-sip rebind responder rtpbreak rtpinsertsound rtpmixsound sctpscan siparmyknife sipp sipvicious sniffjoke sslsplit sslstrip sslyze thc-ipv6 voiphopper webscarab wifi-honey wireshark xspy yersinia zaproxy"
      tools[6]="cryptcat cymothoa dbd dns2tcp http-tunnel httptunnel intersect nishang polenum powersploit pwnat ridenum sbd u3-pwn webshells weevely winexe"
      tools[7]="casefile cutycapt dos2unix dradis keepnote magictree metagoofil nipper-ng pipal"
      tools[8]="armitage backdoor-factory beef-xss cisco-auditing-tool cisco-global-exploiter cisco-ocs cisco-torch crackle exploitdb jboss-autopwn linux-exploit-suggester maltego-teeth set shellnoob sqlmap thc-ipv6 yersinia"
      tools[9]="binwalk bulk-extractor chntpw cuckoo dc3dd ddrescue python-distorm3 dumpzilla volatility xplico foremost galleta guymager iphone-backup-analyzer p0f pdf-parser pdfid pdgmail peepdf extundelete"
      tools[10]="dhcpig funkload iaxflood inviteflood ipv6-toolkit mdk3 reaver rtpflood slowhttptest t50 termineter thc-ipv6 thc-ssl-dos"
      tools[11]="acccheck burpsuite cewl chntpw cisco-auditing-tool cmospwd creddump crunch findmyhash gpp-decrypt hash-identifier hexorbase hydra john johnny keimpx maltego-teeth maskprocessor multiforcer ncrack oclgausscrack pack patator polenum rainbowcrack rcracki-mt rsmangler statsprocessor thc-pptp-bruter truecrack webscarab wordlists zaproxy"
      tools[12]="apktool dex2jar python-distorm3 edb-debugger jad javasnoop smali valgrind yara"
      tools[13]="android-sdk apktool arduino dex2jar sakis3g smali"
      tools[14]="kali-linux kali-linux-full kali-linux-all kali-linux-top10 kali-linux-forensic kali-linux-gpu kali-linux-pwtools kali-linux-rfid kali-linux-sdr kali-linux-voip kali-linux-web kali-linux-wireless squid3"
      tools[15]=$(read_package_ini "$workdir/package.ini")

      export GTK_THEME=CustomTheme

      while true; do
        # Creating the categories array
        categorias=()
        for i in {1..15}; do
          categorias+=("$i - ${categories[$i]}")
        done

        # Displaying the category selection window
        categoria_selecionada=$(yad --center --width 400 --height 450 --title "Select a category" --button "Exit:1" --button "Select:0" --list --column "Categories" "${categorias[@]}")
        codigo_saida=$?

        if [ $codigo_saida -eq 1 ]; then
          show_menu
          break
        fi

        if [ -n "$categoria_selecionada" ]; then
          categoria_selecionada=${categoria_selecionada%% *}
          ferramentas=()
          for ferramenta in ${tools[$categoria_selecionada]}; do
            ferramentas+=("$ferramenta")
          done
          
          # Displaying the tool selection window
          ferramenta_selecionada=$(yad --center --width 400 --height 450 --title "Select a tool" --button "Exit:1" --button "Voltar:2" --button "Select:0" --list --column "Tools" --separator='\n' "${ferramentas[@]}")
          codigo_saida_ferramenta=$?

          if [ $codigo_saida_ferramenta -eq 1 ]; then
            exit 0
          elif [ $codigo_saida_ferramenta -eq 2 ]; then
            continue
          fi

          if [ -n "$ferramenta_selecionada" ]; then
            # Installing the selected tool
            IFS=$'\n' read -r -d '' -a ferramentas_selecionadas <<< "$ferramenta_selecionada"
            all_installed=true
            for ferramenta in "${ferramentas_selecionadas[@]}"; do
              echo -e "\nInstalling $ferramenta..."
              IFS='|' read -r url script depends post_install <<<"${tools[$ferramenta]}"
              if [[ -n $url ]]; then
                if ! git_install "$url" "$script" 2>&1; then
                  error_messages+="Error installing $ferramenta from $url\n"
                  all_installed=false
                fi
              elif [[ -n $post_install ]]; then
                if ! bash -c "$post_install" 2>&1; then
                  error_messages+="Error installing $ferramenta script\n"
                  all_installed=false
                fi
              else
                if ! apt install -y $ferramenta 2>&1; then
                  error_messages+="Error installing $ferramenta with apt:\n$apt_output\n"
                  all_installed=false
                fi
              fi
            done

            if $all_installed; then
              option=$(yad --center --width 200 --height 200 --title "What do you want to do now?" --text "Installation complete!" --button="Back to main menu:1" --button="Back to categories menu:2" --button="Exit:3")
            else
              option=$(yad --center --width 400 --height 300 --title "What do you want to do now?" --text "Installation encountered errors:\n$error_messages" --button="Back to main menu:1" --button="Back to categories menu:2" --button="Exit:3")
            fi
            
            case $? in
              1)
                show_menu
                ;;
              2)
                continue
                ;;
              3)
                exit 0
                ;;
              *)
                ;;
            esac
          fi
        else
          echo "Nenhuma categoria selecionada ou operação cancelada."
          break
        fi
      break
      done
      ;;
    3)
      analize_dependencies
      show_result
      show_menu
      ;;
    4)
      system_upgrade
      show_result
      show_menu
      ;;
    5)
      usage
      show_result
      show_menu
      ;;
    6)
      exit 0
      ;;
    *)
      echo -e "\n\033[1;31mInvalid option. Please choose a valid option.\033[0m"
      show_menu
      ;;
  esac
}

# Define the function to display the verification result
show_result() {
  case $user_option in
    1) echo -e "\n\033[1;32mInstallation completed successfully!\033[0m" ;;
    2) echo -e "\n\033[1;32mDependencies checked successfully!\033[0m" ;;
    3) echo -e "\n\033[1;32mPackages verified successfully!\033[0m" ;;
  esac

  # Ask the user if he wants to return to the main menu or end the script
  echo
  read -r -p "Do you want to return to the main menu or end the script? (y/n) " user_response

  case $user_response in
    y | Y) ;;
    n | N) exit 0 ;;
    *) echo -e "\n\033[1;31mInvalid option. Please choose a valid option.\033[0m" ;;
  esac
}

log_level="INFO"

case $log_level in
"DEBUG")
  log_level=0
  ;;
"INFO")
  log_level=1
  ;;
"WARNING")
  log_level=2
  ;;
"ERROR")
  log_level=3
  ;;
"CRITICAL")
  log_level=4
  ;;
esac

# Error management system
function handle_error() {
  local error="$1"
  echo "Erro: $error" >&2
  exit 1
}

# Caching system
function cache_result() {
  local command="$1"
  local cache_file="$2"
  if [ -f "$cache_file" ]; then
    result=$(cat "$cache_file")
  else
    local result
    result="$($command)"
    echo "$result" >"$cache_file"
    echo "$result"
  fi
}

debug() {
  if [ -x "$APP_DEBUG" ] && $APP_DEBUG ||
    [[ ${APP_DEBUG,,} == @(true|1|on) ]]; then
    echo -e "<!--\n [+] $(cat -A <<<"$*")\n-->"
  fi
}

in_array() {
  local needle=$1 haystack
  printf -v haystack '%s|' "${@:2}"
  [[ "$needle" == @(${haystack%|}) ]]
}

system_update() {
  if [[ ! $is_updated ]]; then
    apt update -y -qq && is_updated=1
  fi
}
export -f system_update

system_upgrade() {
  print_message 'Updating system'
  apt -y upgrade -qq <<<'SYSTEM_UPGRADE'
  apt -y update
  apt -y upgrade -qq
  apt -y full-upgrade -qq
  apt -y dist-upgrade -qq
  apt -f install -qq
  apt --fix-broken install -y
  dpkg --configure -a >/dev/null 2>&1
  apt -y autoremove -qq
  apt -y autoclean -qq
}

check_dependencies() {
  (
    srcdir="$srcdir/DonatoReis/Secbuild/vendor"
    git_install 'https://github.com/NRZCode/progressbar' >/dev/null 2>&1
    git_install 'https://github.com/NRZCode/bash-ini-parser' >/dev/null 2>&1
  )
  source "$workdir/vendor/NRZCode/bash-ini-parser/bash-ini-parser"
}

check_inifile() {
  if [[ ! -r "$inifile" ]]; then
    [[ -r "$workdir/package-dist.ini" ]] &&
      cp "$workdir"/package{-dist,}.ini ||
      wget -qO "$workdir/package.ini" https://github.com/DonatoReis/Secbuild/raw/master/package-dist.ini
    echo "Error: Could not get file package.ini"
    echo "Erro: $?"
    exit 1
  fi
  [[ -r "$inifile" ]] || exit 1
}

init_install() {
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p "$srcdir"
  system_update
  if [[ $force_update == 1 ]]; then
    apt -f install >/dev/null 2>&1
    apt --fix-broken install -y >/dev/null 2>&1
    dpkg --configure -a >/dev/null 2>&1
    rm -f "$HOME"/.local/._first_install.lock
  fi
  # REQUIREMENTS
  print_message 'Complete tool to install and configure various tools for pentesting.'
  printf "\n${CBold}${CFGWhite}◖»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»${CReset}\n\n"
  if [[ ! -f $HOME/.local/._first_install.lock ]]; then
    packages='python3-pip apt-transport-https curl libgtk-4-dev libgdk-pixbuf-2.0-dev libcurl4-openssl-dev libssl-dev jq ruby-full libcurl4-openssl-dev ruby libxml2 libxml2-dev libxslt1-dev ruby-dev dkms build-essential libgmp-dev hcxdumptool zlib1g-dev perl zsh fonts-powerline libio-socket-ssl-perl libdbd-sqlite3-perl libclass-dbi-perl libio-all-lwp-perl libparallel-forkmanager-perl libredis-perl libalgorithm-combinatorics-perl gem git cvs subversion bzr mercurial libssl-dev libffi-dev python-dev-is-python3 ruby-ffi-yajl libldns-dev rename docker.io parsero apache2 ssh tor privoxy proxychains4 aptitude synaptic lolcat yad dialog golang-go graphviz virtualenv reaver bats openssl cargo cmake'
    url='https://go.dev/dl/go1.22.5.linux-amd64.tar.gz'
    wget -O "/tmp/${url##*/}" "$url" >/dev/null 2>&1
    rm -rf /usr/local/go >/dev/null 2>&1
    tar -C /usr/local -xzf "/tmp/${url##*/}" >/dev/null 2>&1
    ln -sf /usr/local/go/bin/go /usr/local/bin/go >/dev/null 2>&1
    case $distro in
    Ubuntu)
      packages+=' chromium-browser whois'
      ;;
    Kali)
      apt -y -qq install kali-desktop-gnome >/dev/null 2>&1
      packages+=' hcxtools amass joomscan uniscan metagoofil gospider zmap crackmapexec arjun dnsgen s3scanner '
      ;;
    esac
    system_upgrade
    apt install -y -qq $packages >/dev/null 2>&1 | progressbar -s normal -m "Installing packages"
    print_message "Installed packages."
    echo

    pip3 install --upgrade pip osrframework py-altdns==1.0.2 requests maigret wfuzz holehe twint droopescan uro arjun dnsgen s3scanner emailfinder pipx one-lin3r win_unicode_console aiodnsbrute webscreenshot dnspython netaddr git-dumper >/dev/null 2>&1 | progressbar -s normal -m "Updating the system"
    print_message "Updated systems."
    echo

    gem install typhoeus opt_parse_validator blunder wpscan --silent | progressbar -s normal -m "Setting up environment"
    print_message "Environment configured."
    echo

    cargo install ppfuzz --quiet >/dev/null 2>&1 | progressbar -s normal -m "Reviewing packages"
    print_message "Revised packages."
    mkdir -p "$HOME/.local"
    >"$HOME"/.local/._first_install.lock
  fi
}

get_distro() {
  if type -t lsb_release >/dev/null 2>&1; then
    distro=$(lsb_release -is)
  elif [[ -f /etc/os-release ||
    -f /usr/lib/os-release ||
    -f /etc/openwrt_release ||
    -f /etc/lsb-release ]]; then
    for file in /usr/lib/os-release /etc/{os-,openwrt_,lsb-}release; do
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
  local inifile="$1"
  local sec url script post_install
  declare -A tools

  cfg_parser "$inifile"

  while read sec; do
    unset url script depends post_install
    cfg_section_$sec 2>&-
    tools[${sec,,}]="$url|$script|$depends|$post_install"
  done < <(cfg_listsections "$inifile")

  # Read tools from package-dist.ini file
  while read -r line; do
    if [[ $line =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
      tool="${BASH_REMATCH[1]}"
      tools["$tool"]=1
    fi
  done < "$inifile"

  echo "${!tools[@]}"
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
      git -C "$installdir" pull $GIT_OPT --all >/dev/null 2>&1
    elif [[ ! -d "$installdir" ]]; then
      git clone $GIT_OPT "$repo" "$installdir" >/dev/null 2>&1
    fi | progressbar -s normal -m "${repo##*/}: Cloning repository"
    if [[ $app ]]; then
      [[ -f "$installdir/$app" ]] && chmod +x "$installdir/$app"
      bin="$bindir/${app##*/}"
      ln -sf "$installdir/$app" "$bin"
      ln -sf "$installdir/$app" "${bin%.*}"
    fi
    if [[ -r "$installdir/requirements.txt" ]]; then
      result=$(
        cd "$installdir"
        pip3 install -q -r requirements.txt 2>>$logerr >>$logfile
      ) | progressbar -s fast -m "${repo##*/}: Python requirements"
    fi
    if [[ -r "$installdir/setup.py" ]]; then
      result=$(
        cd "$installdir"
        python3 setup.py -q install 2>>$logerr >>$logfile
      ) | progressbar -s fast -m "${repo##*/}: Installing setup.py"
    fi
  fi
}

checklist_report() {
  CFGBRed=$'\e[91m'
  CFGBGreen=$'\e[92m'
  if [[ $check_mode == 1 ]]; then
    print_message 'Checklist from package.ini'
    for tool in ${!tools[*]}; do
      IFS='|' read url script depends post_install <<<"${tools[$tool]}"
      if [[ $url || $post_install ]]; then
        [[ "$depends$script" ]] || printf '[%s]\nscript=%s\ndepends=%s\n%s: \e[33mWARNING\e[m: is not possible verify installation: depends is not defined\n\n\n' "$tool" "$script" "$depends" "$tool"
      fi
    done
  fi
  print_message 'Checklist report from tools install'
  for tool in "${!tools[@]}"; do
    IFS='|' read -r url script depends post_install <<<"${tools[$tool]}"
    if [[ $url || $post_install ]]; then
      status=$'Fail'
      if type -t $depends ${script##*/} >/dev/null; then
        status='Ok'
      fi
      echo "${tool^} [$status]"
    fi
  done | column | sed "s/\[Ok\]/[${CFGBGreen}Ok${CReset}]/g;s/\[Fail\]/[${CFGBRed}Fail${CReset}]/g"
}

# Define the function to check dependencies
analize_dependencies() {
  dependencies=("apt" "dpkg" "git" "python3" "cargo")

  for dependency in "${dependencies[@]}"; do
    if ! apt install -y -f "$dependency" >/dev/null 2>&1; then
      echo -e "\nError: $dependency is not installed. Please install it using the command 'apt install $dependency'"
      echo "Installation failed. Please try again."
      exit 1
    fi
  done
}

export -f init_install analize_dependencies system_upgrade system_update

shopt -s extglob
dirname=${BASH_SOURCE%/*}
basename=${0##*/}

export srcdir=${srcdir:-/usr/local}
export bindir=${bindir:-$srcdir/bin}
export GOBIN=$bindir GOPATH=$bindir
workdir="$srcdir/DonatoReis/Secbuild"
logfile="$workdir/${basename%.*}.log"
logerr="$workdir/${basename%.*}.err"
inifile="$workdir/package.ini"
GIT_OPT='-q'
[[ $APP_DEBUG ]] && GIT_OPT=

load_ansi_colors
while [[ $1 ]]; do
  case $1 in
  -h | --help | help)
    usage
    echo -e "${CBold}${CFGYellow}Help:${CReset}"
    printf '%s\n' "\n${CFGWhite}Usage: ./secbuild.sh [-f] [-l] [tool] [-h]${CReset}"
    echo -e "${CFGWhite}{options}:${CReset}"
    echo -e "${CFGWhite}  -h, --help         Show this help${CReset}"
    echo -e "${CFGWhite}  -v, --version      Show the script version${CReset}"
    echo -e "${CFGWhite}  -f, --force-update Force update dependencies${CReset}"
    echo -e "${CFGWhite}  -l, --list         List available security tools${CReset}"
    echo -e "${CFGWhite}  -c, --check        Check if security tools are installed${CReset}"
    exit 0
    ;;
  -v | --version)
    echo -e "${CBold}${CFGYellow}Version:${CReset} ${version}"
    exit 0
    ;;
  -f | --force-update)
    force_update=1
    shift
    ;;
  -l | --list)
    [[ -f "$inifile" ]] && pkgs=$(grep -oP '(?<=^\[)[^]]+' "$inifile")
    echo -e "${CBold}${CFGYellow}Available Security Tools:${CReset}"
    echo -e "${CFGWhite}${pkgs}${CReset}"
    exit 0
    ;;
  -c | --check)
    check_mode=1
    shift
    ;;
  *)
    packages+=("$1")
    shift
    ;;
  esac
done

if [[ 0 != "$EUID" ]]; then
  echo -e "${CBold}${CFGRed}Erro:${CReset} You need to run this script as root!"
  echo -e "${CFGWhite}Used: sudo./$basename${CReset}"
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

show_menu

checklist_report
