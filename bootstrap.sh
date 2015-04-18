#!/bin/bash

shopt -s nocasematch nullglob    # using Bash

dotfiles=${0%/*}
dotfiles_abs=$(cd $dotfiles && pwd -L)

# portable statinode function
case "$(uname -s)" in
    "Linux"   )   statinode() { stat -L -c '%i' "$@"; return 0; };;
    "Darwin"  )   statinode() { stat -L -f '%i' "$@"; return 0; };;
    "FreeBSD" )   statinode() { stat -L -f '%i' "$@"; return 0; };;
    * )           statinode() { ls -id "$@" | cut -d ' ' -f 1; return 0; };;
esac

# run command but only show output if an error occurrs
output_on_error() {
    local log=$(mktemp ${0##*/}_log.XXXXXXXX) || exit 1
    trap 'rm "$log"' RETURN

    $* >$log 2>$log || {
        echo "ERROR:"
        [[ -f $log ]] && cat $log
    }
    # TODO return result or exit on error?
}

# Make a relative path from src -> dst. Stolen from http://stackoverflow.com/a/12498485/31038
make_relative_path() {
    # both $1 and $2 are absolute paths beginning with /
    # returns relative path to $2/$target from $1/$source
    local source=$1
    local target=$2

    local common_part=$source # for now
    local result="" # for now

    while [[ "${target#$common_part}" == "${target}" ]]; do
        # no match, means that candidate common part is not correct
        # go up one level (reduce common part)
        common_part="$(dirname $common_part)"
        # and record that we went back, with correct / handling
        if [[ -z $result ]]; then
            result=".."
        else
            result="../$result"
        fi
    done

    if [[ $common_part == "/" ]]; then
        # special case for root (no common path)
        result="$result/"
    fi

    # since we now have identified the common part,
    # compute the non-common part
    local forward_part="${target#$common_part}"

    # and now stick all parts together
    if [[ -n $result ]] && [[ -n $forward_part ]]; then
        result="$result$forward_part"
    elif [[ -n $forward_part ]]; then
        # extra slash removal
        result="${forward_part:1}"
    fi

    echo $result
}

check_environment() {
    echo "** checking environment"

    local required_exes=(git make curl unzip)

    for e in ${required_exe[@]}; do
        hash $e || {
            echo "!! Missing: $e"
            exit 1
        }
    done

    # Use MacPorts emacs if available
    for e in /Applications/MacPorts/Emacs.app/Contents/MacOS/Emacs ; do
        [[ -x $e ]] || continue
        export EMACS=$e
    done
}

git_config() {
    echo "** setting up git config"

    # Don't use work email name/address for this repo...
    git config --file "$dotfiles/.git/config" user.name "Alastair Rankine"
    git config --file "$dotfiles/.git/config" user.email "alastair@girtby.net"
}

# Make a symbolic link $1 -> $2
make_symlink() {
    local src=$1
    local dst=$2

    if [[ -e $src ]]; then
        if [[ -L $src ]]; then
            local linkinode=$(statinode $src)
            local dstinode=$(statinode $dst)
            if (( linkinode != dstinode )); then
                echo "warning: $src is a symlink but doesn't point to desired $dst ($linkinode != $dstinode)"
            fi
        else
            echo "warning: $src exists, cannot create symlink"
        fi

        return
    fi

    local srcdir=${src%/*}
    local srcnm=${src##*/}
    local dstpath=$(make_relative_path $srcdir $dst)
    echo "   ${srcdir}/${srcnm} -> ${dstpath}"
    (
        cd ${srcdir}
        ln -s ${dstpath} ${srcnm}
    )
}

symlink_dotfiles() {
    echo "** setting up symlinks: ~/.* -> dotfiles/*"

    local skipfiles=(bootstrap.sh readme.org bin)

    for dst in $dotfiles_abs/* ; do
        local nm=${dst##*/}

        # Todo: is this a reliable test?
        if [[ ${skipfiles[*]} =~ $nm ]]; then
            continue
        fi

        make_symlink $HOME/.$nm $dst
    done
}

symlink_bindirs() {
    echo "** setting up symlinks: ~/bin/* -> dotfiles/bin/*"

    [[ -d $HOME/bin ]] || mkdir $HOME/bin

    for dst in $dotfiles_abs/bin/* ; do
        make_symlink $HOME/bin/${dst##*/} $dst
    done
}

clone_git_repo() {
    local path=$1
    local repo=$2

    # Need this because some submodules (like oh-my-zsh) are corrupted on github :(
    local opts="-c transfer.fsckobjects=false"

    if [[ ! -d "$HOME/$path" ]]; then
        echo -n "** clone git repo: $path"
        (
            dir="$HOME/${path%/*}"
            mkdir -p $dir
            cd $dir
            git ${opts} clone -q ${repo} ${path##*/}
        )
        echo " ... done"
    fi
}

get_tarball() {
    # could do something more sophisticated here, but ... nah.
    [[ -d ${HOME}/$1 ]] && return

    echo -n "** installing from tarball: $1 "

    # Make the temp dir here so it is in the same filesystem
    local destdir=${HOME}/${1%/*}
    local tmp=$(mktemp -d ${destdir}/bootstrap.XXXXX) || exit 1
    trap "rm -r ${tmp}" RETURN

    echo -n "... downloading"
    (
        cd ${tmp}
        output_on_error curl -s -O "$2"
    )

    local archive=${2##*/}
    local ext=${archive##*.}
    echo -n "... extracting"
    (
        case ${ext} in
            zip) (
                cd ${tmp}
                output_on_error unzip -q ${archive}
            );;
            # ... add more here?
            *) ;;
        esac
    )

    mv ${tmp}/${archive%.${ext}} ${HOME}/$1
    echo "... done"
}

build_lib() {
    echo -n "** building: $1"

    # Use ginstall-info if available
    hash ginstall-info 2>/dev/null && local install_info_arg="INSTALL-INFO=ginstall-info"

    # Use my Emacs
    [[ $EMACS ]] && local emacs_arg="EMACS=$EMACS"

    (
        cd "$HOME/$1"
        output_on_error make $emacs_arg $install_info_arg
    ) || exit 1
    echo " ... done"
}

run_cask() {
    for op in upgrade "" update; do
        echo -n "** cask $op"
        (
            cd "$HOME/.emacs.d"
            output_on_error $HOME/.emacs.d/extern/cask/bin/cask op
        ) || exit 1
        echo " ... done"
    done
}

# main

check_environment
git_config
symlink_dotfiles
symlink_bindirs

# Some tools are self-updating, so we don't import them as submodules, instead just clone
clone_git_repo ".zsh.d/oh-my-zsh" "https://github.com/robbyrussell/oh-my-zsh.git"
clone_git_repo ".emacs.d/extern/cask" "https://github.com/cask/cask.git"

# Can't get cc-mode from a git mirror, use a snapshot instead
get_tarball ".emacs.d/extern/cc-mode" \
            "http://sourceforge.net/code-snapshots/hg/c/cc/cc-mode/cc-mode/cc-mode-cc-mode-ed795c1c9c7f6e4badac5138e973c28c5ea30fb2.zip"

build_lib ".emacs.d/extern/cc-mode"
build_lib ".emacs.d/extern/cedet"
build_lib ".emacs.d/extern/cedet/contrib"

# run_cask
