#!/bin/sh -fu
#
# THIS SOFTWARE IS IN THE PUBLIC DOMAIN.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# Original version by Securedog <securedog@users.sourceforge.jp>
# Modified by Ken DEGUCHI <kdeguchi@sz.tokoha-u.ac.jp>
# - Support pkgNG
# - Bug fix
# - Cleanup Code


PKG_REPLACE_VERSION=20221128
PKG_REPLACE_CONFIG=FreeBSD

usage() {
	cat <<-EOF
	usage: ${0##*/} [-habBcCfFiJknNOpPPrRuvVwW] [--automatic] [--batch]
	                [--clean] [--cleanup] [--config] [--debug]
	                [--exclude pkename] [--force-config]
	                [--noclean] [--nocleanup] [--noconfig] [--version]
	                [-j jobs] [-l file] [-L prefix] [-m make_args]
	                [-M make_env] [-x pkgname]
	                [[pkgname[=package]] [package] [pkgorigin] ...]
	EOF
	exit 1
}

isempty() {
	case ${@:+1} in
	'')	return 0 ;;
	*)	return 1 ;;
	esac
}

istrue() {
	case ${1:-0} in
	0)	return 1 ;;
	*)	return 0 ;;
	esac
}

warn() {
	echo "** ${@-}" >&2
}

info() {
	echo "--->  ${@-}"
}

prompt_yesno() {
	local X
	echo -n "${1-OK?} [${2-yes}] " >&2
	read X <&1
	case ${X:-${2-yes}} in
	[Yy][Ee][Ss]|[Yy])	return 0 ;;
	*)	return 1 ;;
	esac
}

init_options() {
	opt_all=0
	opt_automatic=0
	opt_backup=1
	opt_batch=0
	opt_keep_backup=0
	opt_config=0
	opt_force_config=0
	opt_force=0
	opt_fetch=0
	opt_interactive=0
	opt_build=0
	opt_keep_going=0
	opt_result=
	opt_log_prefix=
	opt_make_args=
	opt_make_env=
	opt_maxjobs=$(sysctl -n hw.ncpu)
	opt_noexecute=0
	opt_new=0
	opt_package=0
	opt_use_packages=0
	opt_omit_check=0
	opt_noconf=0
	opt_depends=0
	opt_required_by=0
	opt_preserve_libs=1
	opt_verbose=0
	opt_version=0
	opt_beforeclean=0
	opt_afterclean=1
	opt_exclude=
	do_upgrade=0
	do_logging=
	MAKE_ARGS=
	MAKE_ENV=
	BEFOREBUILD=
	BEFOREDEINSTALL=
	AFTERINSTALL=
	IGNORE=
	USE_PKGS=
}

init_variables() {
	init_pkgtools
	: ${MAKE="make"}
	: ${PORTSDIR="$(${PKG_CONFIG} PORTSDIR)"}
	: ${OVERLAYS="$(cd ${PORTSDIR} && ${MAKE} -V OVERLAYS)"}
	: ${PKGREPOSITORY="$(${PKG_CONFIG} PKG_CACHEDIR)/All"}
	: ${PACKAGEROOT="https://pkg.FreeBSD.org"}
	: ${PKG_DBDIR="$(${PKG_CONFIG} PKG_DBDIR)"}
	: ${PKG_BINARY_SUFX="$(cd ${PORTSDIR} && ${MAKE} -V PKG_SUFX -f "Mk/bsd.port.mk")"}
	: ${PKG_FETCH="$(cd ${PORTSDIR} && ${MAKE} -V FETCH_CMD -f "Mk/bsd.port.mk" || echo fetch)"}
	: ${PKG_BACKUP_DIR=${PKGREPOSITORY}}
	: ${PKG_TMPDIR=${TMPDIR:-"/var/tmp"}}
	: ${PKGCOMPATDIR="%%PKGCOMPATDIR%%"}
	export PORTSDIR OVERLAYS PKG_DBDIR PKG_TMPDIR PKG_BINARY_SUFX PKGCOMPATDIR
	tmpdir=
	set_signal_int=
	set_signal_exit=
	optind=1
	log_file=
	log_format="+:done -:ignored *:skipped !:failed"
	log_length=0
	log_summary=
	cnt_done=
	cnt_ignored=
	cnt_skipped=
	cnt_failed=
	err=
	result=
	install_pkgs=
	upgrade_pkgs=
	replace_pkgs=
	failed_pkgs=
	preserved_files=
	pkg_name=
	pkg_origin=
	pkg_portdir=
	pkg_binary=
	pkg_flavor=
}

init_pkgtools() {
	PKG_BIN="pkg"
	PKG_ADD="${PKG_BIN} add"
	PKG_ANNOTATE="${PKG_BIN} annotate"
	PKG_CHECK="${PKG_BIN} check"
	PKG_CONFIG="${PKG_BIN} config"
	PKG_CREATE="${PKG_BIN} create"
	PKG_DELETE="${PKG_BIN} delete"
	PKG_INFO="${PKG_BIN} info"
	PKG_QUERY="${PKG_BIN} query"
	PKG_SET="${PKG_BIN} set"
}

parse_options() {
	local long_opts long_optind X

	long_opts=
	long_optind=0

	for X in ${1+"$@"}; do
		case $X in
		--)	break ;;
		--*)	shift
			long_opts="${long_opts} ${X#--}"
			long_optind=$((long_optind+1)) ;;
		*)	shift; set -- ${1+"$@"} "$X" ;;
		esac
	done

	for X in ${long_opts}; do
		case $X in
		automatic)	opt_automatic=1 ;;
		batch)		opt_batch=1 ;;
		config)		opt_config=1 ;;
		clean)		opt_beforeclean=1 ;;
		cleanup)	opt_afterclean=1 ;;
		debug)		set -x ;;
		exclude)	opt_exclude=1;;
		force-config)	opt_force_config=1 ;;
		noclean)	opt_beforeclean=0 ;;
		nocleanup)	opt_afterclean=0 ;;
		noconfig)	opt_noconf=1 ;;
		version)	echo ${PKG_REPLACE_VERSION}; exit 0 ;;
		*)	usage ;;
		esac
	done

	while getopts habBcCdfFiIJj:kl:L:m:M:nNOpPrRuvVwWx: X; do
		case $X in
		a)	opt_all=1 ;;
		b)	opt_keep_backup=1 ;;
		B)	opt_backup=0 ;;
		c)	opt_config=1 ;;
		C)	opt_force_config=1 ;;
		d)	opt_depends=1 ;;
		f)	opt_force=1 ;;
		F)	opt_fetch=1 ;;
		i)	opt_interactive=1 ;;
		J)	opt_build=1 ;;
		j)	opt_maxjobs=$( [ ${OPTARG} -ge 1 ] 2> /dev/null && echo ${OPTARG} || sysctl -n hw.ncpu ) ;;
		k)	opt_keep_going=1 ;;
		l)	expand_path 'opt_result' "${OPTARG}" ;;
		L)	expand_path 'opt_log_prefix' "${OPTARG}" ;;
		m)	opt_make_args="${opt_make_args} ${OPTARG}" ;;
		M)	opt_make_env="${opt_make_env} ${OPTARG}" ;;
		n)	opt_noexecute=1 ;;
		N)	opt_new=1 ;;
		O)	opt_omit_check=1 ;;
		p)	opt_package=1 ;;
		P)	opt_use_packages=$((opt_use_packages+1)) ;;
		r)	opt_required_by=1 ;;
		R)	opt_depends=1 ;;
		u)	opt_preserve_libs=0 ;;
		v)	opt_verbose=1 ;;
		V)	opt_version=1 ;;
		w)	opt_beforeclean=0 ;;
		W)	opt_afterclean=0 ;;
		x)	opt_exclude="${opt_exclude} ${OPTARG}" ;;
		*)	usage ;;
		esac
	done

	istrue ${opt_batch} && opt_config=0
	istrue ${opt_batch} && opt_force_config=0
	istrue ${opt_depends} && opt_omit_check=0
	istrue ${opt_force_config} && opt_config=0
	istrue ${opt_omit_check} && opt_keep_going=1

	optind=$((OPTIND+long_optind))
}

parse_args() {
	local _ARG _pkg __pkg _portdir _deps _reqs _p

	for _ARG in ${1+"$@"}; do
		pkg_flavor=; _pkg=; _portdir=; _dpes=; _reqs=

		case ${_ARG} in
		\\*)	_ARG=${_ARG#\\} ;;
		?*=*)	_pkg=${_ARG#*=}; _ARG=${_ARG%%=*} ;;
		esac

		_ARG=${_ARG%/}

		case ${_ARG} in
		*${PKG_BINARY_SUFX})
			[ ! -e "${_ARG}" ] && warn "'${_ARG}' does not exist." && continue
			get_binary_pkgname '_pkg' "${_ARG}" || continue
			get_installed_pkgname '__pkg' ${_pkg} && \
				install_pkgs="${install_pkgs} ${_ARG}" && continue
			;;
		*@*/*)	;;
		*/*@*)
			pkg_flavor=${_ARG##*@}
			_origin=${_ARG%@*}
			for _overlay in ${OVERLAYS} ${PORTSDIR}; do
				[ -d "${_overlay}/${_origin}" ] &&
					_portdir="${_overlay}/${_origin}" && break
				[ -d "${_origin}" ] && cd "${_origin}" &&
					_portdir=$( pwd ) && _origin=${_portdir#${_overlay}/} && break
			done
			if get_pkgname_from_portdir '_ARG' "${_portdir}"; then
				_ARG="${_ARG}"
			else
				warn "No such file or package: ${_portdir}"
				continue
			fi ;;
		*)
			for _overlay in ${OVERLAYS} ${PORTSDIR}; do
				[ -d "${_overlay}/${_ARG}" ] &&
					_ARG="${_ARG}" && break
				[ -d "${_ARG}" ] && cd "${_ARG}" &&
					_portdir=$( pwd ) && _ARG="${_portdir#${_overlay}/}" && break
			done
			_ARG="${_ARG}" ;;
		esac

		if get_installed_pkgname '__pkg' "${_ARG}"; then
			if istrue ${opt_depends}; then
				get_depend_pkgnames '_deps' "${__pkg}"
				upgrade_pkgs="${upgrade_pkgs} ${_deps}"
			fi
			upgrade_pkgs="${upgrade_pkgs} ${__pkg}"
			if istrue ${opt_required_by}; then
				get_require_pkgnames '_reqs' "${__pkg}"
				upgrade_pkgs="${upgrade_pkgs} ${_reqs}"
			fi
			for _p in ${__pkg}; do
				replace_pkgs="${replace_pkgs}${_pkg:+ ${_p}=${_pkg}}"
			done
		elif istrue ${opt_new}; then
			if isempty ${pkg_flavor}; then
				install_pkgs="${install_pkgs} ${_ARG}"
			else
				install_pkgs="${install_pkgs} ${_origin}@${pkg_flavor}"
			fi
		else
			warn "No such file or package: ${_ARG}"
			continue
		fi

	done
}

parse_config() {
	local _line _var _val _array _func _X

	[ -r "$1" ] || return 0

	_line=0
	_array=
	_func=

	while read -r _X; do
		_line=$((_line+1))

		case ${_X} in
		''|\#*)	continue ;;
		esac

		case ${_func:+function}${_array:+array} in
		function)
			_func="${_func}
${_X}"
			case ${_X} in
			'}'|'};')
				eval "${_func}"
				_func= ;;
			esac ;;
		array)
			case ${_X} in
			*[\'\"]?*[\'\"]*)
				_var=${_X#*[\'\"]}
				_var=${_var%%[\'\"]*}

				case ${_X} in
				*=\>*[\'\"]*[\'\"]*)
					_val=${_X#*=\>*[\'\"]}
					_val=${_val%[\'\"]*}
					eval ${_array}='"${'${_array}':+$'${_array}'
}${_var}=${_val}"' ;;
				*)
					eval ${_array}='"$'${_array}' ${_var}"' ;;
				esac ;;
			[\)}]|[\)}]\;)
				_array= ;;
			*)
				warn "Syntax error at line ${_line}: ${_X}"
				return 1 ;;
			esac ;;
		*)
			case ${_X} in
			*\(\)|*\(\)*{)
				_var=${_X%%\(\)*}
				_var=${_var%${_var##*[! ]}}
				_func="${_X}" ;;
			?*=*)
				_var=${_X%%=*}
				_val=${_X#*=} ;;
			*)	_var="syntax-error" ;;
			esac

			case ${_var} in
			*[!0-9A-Za-z_]*|[0-9]*)
				warn "Syntax error at line ${_line}: ${_X}"
				return 1 ;;
			esac

			case ${_func:+1} in
			1)	continue ;;
			esac

			case ${_val} in
			*[\({])
				eval ${_var}=; _array=${_var} ;;
			*)	eval ${_var}=${_val} ;;
			esac ;;
		esac
	done < "$1"
}

config_match() {
	case "|${pkg_name}|${pkg_name%-*}|${pkg_origin}|" in
	*\|$1\|*)
		return 0 ;;
	*)	return 1 ;;
	esac
}

has_config() {
	local _config _X

	eval _config=\$$1
	for _X in ${_config}; do
		if config_match "${_X%%=*}"; then
			return 0
		fi
	done
	return 1
}

get_config() {
	local IFS _config _X
	IFS='
'
	eval _config=\$$2
	eval $1=
	for _X in ${_config}; do
		if config_match "${_X%%=*}"; then
			eval $1='"${'$1':+$'$1'${3- }}${_X#*=}"'
		fi
	done
}

run_config_script() {
	local _command

	get_config '_command' "$1" '; '
	if ! isempty ${_command}; then
		info "Executing the $1 command: ${_command}"
		( set +efu -- "${2:-${pkg_name-}}" "${3:-${pkg_origin-}}"; eval "${_command}" )
	fi
}

run_rc_script() {
	local _files _X
	_files="$(${PKG_QUERY} '%Fp' $1)"
	for _X in ${_files}; do
		case ${_X} in
		*.sample) ;;
		*/etc/rc.d/*)
			if [ -x "${_X}" ]; then
				info "Executing '${_X} $2'"
				try "${_X}" "$2"
			fi ;;
		esac
	done
}

cmd_start_rc() {
	run_rc_script "$1" start
}

cmd_stop_rc() {
	run_rc_script "$1" stop
}

cmd_restart_rc() {
	run_rc_script "$1" restart
}

load_config() {
	if ! isempty ${1-} && ! istrue ${opt_noconf}; then
		istrue ${opt_verbose} && info "Loading $1"

		parse_config "$1" || {
			warn "Fatal error in $1."
			exit 1
		}
	fi
}

load_make_vars() {
	get_config 'PKG_MAKE_ARGS' 'MAKE_ARGS'
	PKG_MAKE_ARGS="${opt_make_args:+${opt_make_args} }${PKG_MAKE_ARGS}"
	case "${PKG_MAKE_ARGS}" in
		*FLAVOR=*)	pkg_flavor=${PKG_MAKE_ARGS##*FLAVOR=}; pkg_flavor=${pkg_flavor% *} ;;
	esac
	! isempty "${pkg_flavor}" && PKG_MAKE_ARGS="${PKG_MAKE_ARGS} FLAVOR=${pkg_flavor}"
	get_config 'PKG_MAKE_ENV' 'MAKE_ENV'
	! isempty "${opt_maxjobs}" &&
		PKG_MAKE_ENV="${PKG_MAKE_ENV} MAKE_JOBS_NUMBER_LIMIT=${opt_maxjobs}"
	PKG_MAKE_ENV="${opt_make_env:+${opt_make_env} }${PKG_MAKE_ENV}"
	! isempty "${PKG_MAKE_ENV}" && PKG_MAKE_ENV="env ${PKG_MAKE_ENV} "
	PKG_MAKE="${PKG_MAKE_ENV}${MAKE}${PKG_MAKE_ARGS:+ ${PKG_MAKE_ARGS}}"
}

load_upgrade_vars() {
	PKG_MAKE="${PKG_MAKE} UPGRADE_TOOL=pkg_replace UPGRADE_PORT=$1 UPGRADE_PORT_VER=${1##*-}"
}

load_env_vars() {
	set -- ${PKG_REPLACE_ENV=$(uname -smr)}

	OPSYS=$1
	OS_VERSION=$2
	OS_REVISION=${OS_VERSION%%[-_]*}
	OS_MAJOR=${OS_REVISION%%.*}
	ARCH=$3
}

get_installed_pkgname() {
	local __pkgname
	__pkgname=$( ${PKG_QUERY} -g '%n-%v' "$2" 2> /dev/null || echo -n '' )
	isempty ${__pkgname} && return 1
	eval $1=\${__pkgname}
}

get_origin_from_pkgname() {
	local __origin
	__origin=$(${PKG_QUERY} '%o' "$2")
	isempty ${__origin} && return 1
	eval $1=\${__origin}
}

get_pkgname_from_portdir() {
	local __pkgname __flavor 
	[ ! -d "$2" ] && return 1
	load_make_vars
#	! isempty ${pkg_flavor} && {
#		case X"$(cd "$2" && ${PKG_MAKE} -VFLAVORS)" in
#		*${pkg_flavor}*)	;;
#		X)	;;
#		*)	warn "FLAVOR=${pkg_flavor} is not exist!"; exit 1 ;;
#		esac
#	}
	__pkgname=$(cd "$2" && ${PKG_MAKE} -VPKGNAME)
	isempty ${__pkgname} && return 1
	eval $1=\${__pkgname}
}

get_portdir_from_origin() {
	local __portdir __overlay
	__portdir=
	for __overlay in ${OVERLAYS} ${PORTSDIR}; do
		[ -e "${__overlay}/$2/Makefile" ] && __portdir="${__overlay}/$2" && break
	done
	eval $1=\${__portdir}
}

get_pkgname_from_origin() {
	local __pkgname
	__pkgname=$(${PKG_QUERY} '%n-%v' "$2")
	isempty ${__pkgname} && return 1
	eval $1=\${__pkgname}
}

get_depend_pkgnames() {
	local __pkgnames
	__pkgnames=$(${PKG_QUERY} '%dn-%dv' $2 | sort -u)
	eval $1=\${__pkgnames}
}

get_require_pkgnames() {
	local __pkgnames
	__pkgnames=$(${PKG_QUERY} '%rn-%rv' $2 | sort -u)
	eval $1=\${__pkgnames}
}

get_binary_pkgname() {
	local __binary_pkgname
	__binary_pkgname=$(${PKG_QUERY} -F "$2" '%n-%v')
	if isempty ${__binary_pkgname}; then
		warn "'$2' is not a valid package."
		return 1
	fi
	eval $1=\${__binary_pkgname}
}

get_binary_origin() {
	local __binary_origin
	__binary_origin=$(${PKG_QUERY} -F "$2" '%o')
	isempty ${__binary_origin} && return 1
	eval $1=\${__binary_origin}
}

get_binary_flavor(){
	local __binary_flavor
	__binary_flavor=$(${PKG_QUERY} -F "$2" '%At %Av' | grep flavor | cut -d' ' -f 2)
	eval $1=\${__binary_flavor}
}

get_depend_binary_pkgnames() {
	local _origins _origin _portdir _pkgname
	_origins=
	for _origin in $(${PKG_QUERY} -F "$2" '%do'); do
		isempty "${_origin}" && continue
		get_portdir_from_origin '_portdir' ${_origin}
		get_pkgname_from_portdir '_pkgname' ${_portdir}
		_origins="${_origins} ${_pkgname}:${_origin}"
	done
	eval $1=\${_origins}
}

set_portinfo() {
	pkg_origin="$1"
	get_portdir_from_origin 'pkg_portdir' "$1"
	get_pkgname_from_portdir 'pkg_name' "${pkg_portdir}" || return 1
	pkg_binary=
}

set_binary_pkginfo() {
	get_binary_pkgname 'pkg_name' "$1" || return 1
	get_binary_origin 'pkg_origin' "$1"
	get_binary_flavor 'pkg_flavor' "$1"
	get_portdir_from_origin 'pkg_portdir' ${pkg_origin}
	pkg_binary="$1"
}

pkg_sort() {
	local _ret _pkgs _pkg _cnt _dep_list __dep_list

	_ret="$1"; shift

	case $# in
	0|1)	eval ${_ret}=\$@; return 0 ;;
	esac

	_pkgs=$@

	# check installed package
	${PKG_INFO} -e ${_pkgs} 2>&1 > /dev/null || return 1

	echo -n 'Checking dependencies'
	_dep_list= ; _cnt=0
	# check dependencies
	while : ; do
		echo -n '.'
		_dep_list=${_dep_list}$(echo ${_pkgs} | tr ' ' '\n' | \
			sed "s/^/${_cnt}:/")' '
		get_depend_pkgnames '_pkgs' "${_pkgs}"
		[ -z "${_pkgs}" ] && echo 'done.' && break
		_cnt=$((_cnt+1))
	done
	__dep_list=$(echo ${_dep_list} | tr ' ' '\n' | sort -u | \
		sort -t: -k 1nr -k 2 | cut -d: -f 2)

	# delete duplicate package
	_dep_list=
	for _pkg in ${__dep_list}; do
		case " ${_dep_list} " in
		*\ ${_pkg}\ *)	continue ;;
		*)	_dep_list="${_dep_list}${_pkg} " ;;
		esac
	done

	# only pkgs
	__dep_list=${_dep_list}
	_dep_list=
	for _pkg in ${__dep_list}; do
		case " $@ " in
		*\ ${_pkg}\ *)	_dep_list="${_dep_list}${_pkg} " ;;
		*)	continue ;;
		esac
	done

	eval ${_ret}=\${_dep_list}
}

create_tmpdir() {
	if isempty ${tmpdir}; then
		tmpdir=$(mktemp -d "${PKG_TMPDIR}/${0##*/}.XXXXXX") || {
			warn "Couldn't create the working directory."
			return 1
		}
	fi
}

clean_tmpdir() {
	if ! isempty ${tmpdir}; then
		try rmdir "${tmpdir}" ||
			warn "Couldn't remove the working direcotry: ${tmpdir}"
		tmpdir=
	fi
}

create_file() {
	if ! true > "$1"; then
		warn "Failed to create file: $1"
		return 1
	fi
}

create_dir() {
	if [ ! -d "$1" ]; then
		try mkdir -p "$1" || return 1
	fi
}

expand_path() {
	case "$2" in
	[!/]*)	eval $1='"${PWD:-`pwd`}/${2#./}"' ;;
	*)	eval $1=\$2 ;;
	esac
}

try() {
	local _errno
	"$@" || {
		_errno=$?
		warn "Command failed (exit code ${_errno}): $@"
		return ${_errno}
	}
}

xtry() {
	if isempty ${do_logging}; then
		try "$@" || return $?
	else
		try script -qa "${do_logging}" "$@" || return $?
	fi
}

build_package() {
	local _build_args

	_build_args=

	if istrue ${opt_fetch}; then
		_build_args="-DBATCH checksum"
		info "Fetching '$1'"
	else
		istrue ${opt_package} && _build_args="DEPENDS_TARGET=install"
		istrue ${opt_batch} && _build_args="${build_args} -DBATCH"
		info "Building '$1'${PKG_MAKE_ARGS:+ with make flags: ${PKG_MAKE_ARGS}}"
	fi

	cd "$1" || return 1

	if ! istrue ${opt_fetch}; then
		run_config_script 'BEFOREBUILD'
		if istrue ${opt_beforeclean}; then
			clean_package "$1" || return 1
		fi
	fi

	xtry ${PKG_MAKE} ${_build_args} || return 1

	(istrue ${opt_package} && xtry ${PKG_MAKE} package || return 1) || return 0

}

set_automatic_flag() {
	${PKG_SET} -y -A "$2" "$(${PKG_QUERY} '%n-%v' $1)" 2> /dev/null
}

install_pkg_binary_depends() {
	local _deps _dep_name _dep_origin _installed_pkg _X

	info "Installing dependencies for '$1'"

	get_depend_binary_pkgnames '_deps' "$1"
	for _X in ${_deps}; do
		_dep_name=${_X%:*}
		_dep_origin=${_X##*:}
		if {
			get_installed_pkgname '_installed_pkg' "${_dep_name%-*}" ||
			get_pkgname_from_origin '_installed_pkg' "${_dep_origin}"
		}; then
			info " Required installed package: ${_dep_name} - installed"
		else
			info " Required installed package: ${_dep_name} - not installed"
			( opt_build=0; do_install "${_dep_origin}" && [ "${result}" = "done" ] ) ||
			{
				warn "Failed to install '${_dep_origin}'"
				return 1
			}
			set_automatic_flag "${_dep_origin}" '1' || return 1
			info "Returning to install of '$1'"
		fi
	done
}

install_pkg_binary() {
	local _install_args
	_install_args=
	info "Installing '$1'"
	istrue ${opt_force} && _install_args="-f"
	xtry ${PKG_ADD} ${_install_args} $1 || return 1
	run_config_script 'AFTERINSTALL'
}

install_package() {
	local _install_args
	_install_args=

	info "Installing '$1'"

	istrue ${opt_force} && _install_args="-DFORCE_PKG_REGISTER"
	istrue ${opt_batch} && _install_args="${_install_args} -DBATCH"

	cd "$1" || return 1
	xtry ${PKG_MAKE} ${_install_args} reinstall || return 1
	if istrue ${opt_afterclean}; then
		clean_package "$1"
	fi

	run_config_script 'AFTERINSTALL'
}

deinstall_package() {
	local _deinstall_args
	_deinstall_args=

	istrue ${do_upgrade} || istrue ${opt_force} && _deinstall_args="-f"
	_deinstall_args="${_deinstall_args} -y" || \
		(istrue ${opt_verbose} && _deinstall_args="${_deinstall_args} -v")

	info "Deinstalling '$1'"

	if [ ! -w "${PKG_DBDIR}" ]; then
		warn "You do not own ${PKG_DBDIR}."
		return 1
	fi

	run_config_script 'BEFOREDEINSTALL' "$1"

	try ${PKG_DELETE} ${_deinstall_args} $1 || return 1
}

clean_package() {
	local _clean_args
	_clean_args=

	info "Cleaning '$1'"

	cd "$1" || return 1

	try ${PKG_MAKE} ${_clean_args} clean || return 1
}

do_fetch() {
	local _fetch_cmd _fetch_args _fetch_path

	_fetch_path=${2:-${1##*/}}
	_fetch_cmd=${PKG_FETCH%%[$IFS]*}
	_fetch_args=${PKG_FETCH#${_fetch_cmd}}

	case ${_fetch_cmd##*/} in
	curl|fetch|ftp|axel)	_fetch_args="${_fetch_args} -o ${_fetch_path}" ;;
	wget)	_fetch_args="${_fetch_args} -O ${_fetch_path}" ;;
	esac

	case ${_fetch_path} in
	*/*)	cd "${_fetch_path%/*}/" || return 1 ;;
	esac

	try "${_fetch_cmd}" ${_fetch_args} "$1"

	if [ ! -s "${_fetch_path}" ]; then
		warn "Failed to fetch: $1"
		try rm -f "${_fetch_path}"
		return 1
	fi
}

fetch_package() {
	local _pkg _uri _uri_path

	_pkg=$1${PKG_BINARY_SUFX}
	if [ -e "${PKGREPOSITORY}/${_pkg}" ]; then
		return 0
	elif ! create_dir "${PKGREPOSITORY}" || [ ! -w "${PKGREPOSITORY}" ]; then
		warn "You do not own ${PKGREPOSITORY}."
		return 1
	fi

	load_env_vars

	if ! isempty ${PACKAGESITE-}; then
		_uri="${PACKAGESITE}${_pkg}"
	else
		_uri_path="/$(${PKG_CONFIG} abi)/latest/All/"
		_uri="${PACKAGEROOT}${_uri_path}${_pkg}"
	fi

	do_fetch "${_uri}" "${PKGREPOSITORY}/${_pkg}" || return 1
}

find_package() {
	local _X

	_X="${PKGREPOSITORY}/$2${PKG_BINARY_SUFX}"

	if [ -e "${_X}" ]; then
		info "Found a package of '$2': ${_X}"
		eval $1=\${_X}
	else
		return 1
	fi
}

create_package() {
	try ${PKG_CREATE} -o ${2%/*} "$1" || return 1
}

backup_package() {
	if istrue ${opt_backup} && [ ! -e "$2" ]; then
		info "Backing up the old version"
		create_package "$1" "$2" || [ -s "$2" ] || return 1
	fi
}

backup_file() {
	if [ -e "$1" ]; then
		info "Backing up the ${1##*/} file"
		try cp -f "$1" "$2" || return 1
	fi
}

restore_package() {
	if [ -e "$1" ]; then
		info "Restoring the old version"
		install_pkg_binary "$1" || return 1
	else
		return 1
	fi
}

restore_file() {
	if [ -e "$1" ] && [ ! -e "$2" ]; then
		info "Restoring the ${1##*/} file"
		try mv -f "$1" "$2" || return 1
	fi
}

process_package() {
	if istrue ${opt_keep_backup} && [ -e "$1" ] && [ ! -e "${PKG_BACKUP_DIR}/${1##*/}" ]; then
		info "Keeping the old version in '${PKG_BACKUP_DIR}'"
		create_dir "${PKG_BACKUP_DIR}" || return 1
		try mv -f "$1" "${PKG_BACKUP_DIR}" || return 1
	fi
}

preserve_libs() {
	local _files _X
	istrue ${opt_preserve_libs} || return 0
	preserved_files=
	_files="$(${PKG_QUERY} '%Fp' $1)"
	for _X in ${_files}; do
		case ${_X##*/} in
		*.so.[0-9]*|*.so)
			[ -f "${_X}" ] && preserved_files="${preserved_files} ${_X}" ;;
		esac
	done
	if ! isempty ${preserved_files}; then
		info "Preserving the shared libraries"
		create_dir "${PKGCOMPATDIR}" || return 1
		try cp -af ${preserved_files} "${PKGCOMPATDIR}" || return 1
	fi
}

clean_libs() {
	local _del_files _dest _X
	if istrue ${opt_preserve_libs} || isempty ${preserved_files}; then
		return 0
	fi
	info "Cleaning the preserved shared libraries"
	_del_files=
	for _X in ${preserved_files}; do
		_dest="${PKGCOMPATDIR}/${_X##*/}"
		if [ -e "${_dest}" ]; then
			_del_files="${_del_files} ${_dest}"
		else
			info "Keeping ${_X} as ${_dest}"
		fi
	done
	if ! isempty ${_del_files}; then
		try rm -f ${_del_files} || return 1
	fi
}

parse_moved() {
	local IFS _ret _info _origin _new_origin _portdir
	local _date _why _checked

	_ret=$1; eval $1=
	_info=$2; eval $2=
	_origin=$3; _checked=

	IFS='|'
	while X=$(grep "^${_origin}|" "${PORTSDIR}/MOVED"); do
		set -- $X
		_origin=${1-}; _new_origin=${2-}; _date=${3-}; _why=${4-}

		case "$#:${_checked}:" in
		[!4]:*|?:*:${_new_origin}:*)
			warn "MOVED may be broken"
			return 1
		esac

		_checked="${_checked}:${_origin}"
		_origin=${_new_origin}
		eval ${_info}='"${_why} (${_date})"'

		if isempty ${_new_origin}; then
			eval ${_ret}=removed
			break
		fi

		get_portdir_from_origin '_portdir' ${_new_origin}
		! isempty ${_portdir} && eval ${_ret}=\${_new_origin} && break

	done
}

trace_moved() {
	local _moved _reason

	parse_moved '_moved' '_reason' "$1" || return 1

	case ${_moved} in
	'')
		warn "Path is wrong or has no Makefile:"
		return 1 ;;
	removed)
		warn "'$1' has removed from ports tree:"
		warn "    ${_reason}"
		return 1 ;;
	*)
		warn "'$1' has moved to '${_moved}':"
		warn "    ${_reason}"
		pkg_origin=${_moved}
		get_portdir_from_origin 'pkg_portdir' ${_moved}
		;;
	esac
}

init_result() {
	local _X

	log_file="${tmpdir}/${0##*/}.log"
	create_file "${log_file}" || return 1

	for _X in ${log_format}; do
		eval cnt_${_X#*:}=0
		eval log_sign_${_X#*:}=${_X%%:*}
		log_summary="${log_summary:+${log_summary}, }\${cnt_${_X#*:}} ${_X#*:}"
	done
}

set_result() {
	log_length=$((log_length+1))
	eval cnt_$2=$((cnt_$2+1))
	eval 'echo "${log_sign_'$2'} $1${3:+ ($3)}" >> "${log_file}"'
}

show_result() {
	local _mask _descr _X

	_mask=
	_descr=
	istrue ${log_length} || return 0

	for _X in ${log_format}; do
		case ${_X#*:} in
		failed)
			istrue ${cnt_failed} || continue ;;
		skipped)
			istrue ${cnt_skipped} || continue ;;
		*)	istrue ${opt_verbose} || continue ;;
		esac
		_mask="${_mask}${_X%%:*}"
		_descr="${_descr:+${_descr} / }${_X}"
	done

	if ! isempty ${_mask}; then
		info "Listing the results (${_descr})"
		while read _X; do
			case ${_X%% *} in
			["${_mask}"])
				echo "        ${_X}" ;;
			esac
		done < "${log_file}"
	fi
}

write_result() {
	if ! isempty "$1"; then
		try cp -f "${log_file}" "$1" || return 0
	fi
	try rm -f "${log_file}"
}

set_signal_handlers() {
	trap "warn Interrupted.; ${set_signal_int:+${set_signal_int};} exit 1" 1 2 3 15
	trap "${set_signal_exit:--}" 0
}


set_pkginfo_install() {
	case "$1" in
	*${PKG_BINARY_SUFX})	set_binary_pkginfo "$1" || return 1 ;;
	*/*@*)
		pkg_origin="${1%@*}"
		if [ -d "${pkg_origin}" ]; then
			pkg_portdir=${pkg_origin}
		else
			get_portdir_from_origin 'pkg_portdir' ${pkg_origin}
		fi
		pkg_flavor="${1##*@}" ;;
	*)	set_portinfo "$1" || return 1 ;;
	esac
}

set_pkginfo_replace() {
	local _X

	pkg_name="$1"
	get_origin_from_pkgname 'pkg_origin' "${pkg_name}"
	pkg_binary=
	pkg_portdir=

	get_portdir_from_origin 'pkg_portdir' ${pkg_origin}

	isempty ${pkg_flavor} &&
		pkg_flavor=$( ${PKG_ANNOTATE} --quiet --show "$1" flavor )

	for _X in ${replace_pkgs}; do
		case ${pkg_name} in
		"${_X%%=*}")
			_X=${_X#*=}
			case "${_X}" in
			*${PKG_BINARY_SUFX})	pkg_binary=${_X} ;;
			*/*@*)
				pkg_origin="${_X%@*}"
				if [ -d "${pkg_origin}" ]; then
					pkg_portdir=${pkg_origin}
				else
					get_portdir_from_origin 'pkg_portdir' ${pkg_origin}
				fi
				pkg_flavor="${_X##*@}" ;;
			*)	pkg_portdir="${_X}"; pkg_origin="${pkg_origin}" ;;
			esac
			break ;;
		esac
	done

	if isempty ${pkg_binary}; then
		if isempty ${pkg_origin}; then
			err="not installed or no origin recorded"
			return 1
		elif [ ! -e "${pkg_portdir}/Makefile" ]; then
			trace_moved "${pkg_origin}" || { err="removed"; return 1; }
		fi
		get_pkgname_from_portdir 'pkg_name' "${pkg_portdir}" || return 1
	else
		get_binary_pkgname 'pkg_name' "${pkg_binary}" || return 1
		get_binary_flavor 'pkg_flavor' "${pkg_binary}" || return 1
	fi
}

make_config_conditional() {
    (cd "$1" && ${PKG_MAKE} config-conditional) || return 1
}

make_config() {
    (cd "$1" && ${PKG_MAKE} config) || return 1
}

do_install_config() {
	err=; result=

	set_pkginfo_install "$1" || {
		warn "Skipping '$1'${err:+ - ${err}}."
		result="skipped"
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${pkg_name}' - ignored"
		return 0
	fi

	if istrue ${opt_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config-conditional: %-${#2}s\\r" "$1"
		xtry make_config_conditional "${pkg_portdir}" || {
			err="config-conditional error"
			return 1
		}
	fi

	if istrue ${opt_force_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config: %-${#2}s\\r" "$1"
		xtry make_config "${pkg_portdir}" || {
			err="config error"
			return 1
		}
	fi
}

do_install() {
	err=; result=
	local _cur_pkgname _pkg

	case "$1" in
	*/*@*)	pkg_flavor="${1##*@}"; _pkg=${1%@*} ;;
	*)	_pkg="$1" ;;
	esac

	set_pkginfo_install "${_pkg}" || {
		warn "Skipping '$_pkg'${err:+ - ${err}}."
		result="skipped"
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${pkg_name}' - ignored"
		return 0
	fi

	if ! istrue ${opt_force} && isempty ${pkg_flavor} && get_pkgname_from_origin '_cur_pkgname' "${pkg_origin}"; then
		info "Skipping '${pkg_origin}' - '${_cur_pkgname}' is already installed"
		return 0
	fi

	info "Installing '${pkg_name}' from '$_pkg'"

	if istrue ${opt_noexecute}; then
		result="done"
		return 0
	elif istrue ${opt_interactive}; then
		prompt_yesno || return 0
	fi

	do_logging=${opt_log_prefix:+"${opt_log_prefix}${pkg_name}.log"}

	if isempty ${pkg_binary} && has_config 'USE_PKGS'; then
		if fetch_package "${pkg_name}"; then
			find_package 'pkg_binary' "${pkg_name}" || return 1
		else
			case ${opt_use_packages} in
			1)	warn "Using the source instead of the binary package." ;;
			*)	err="package not found"; return 1 ;;
			esac
		fi
	fi

	if isempty ${pkg_binary}; then
		build_package "${pkg_portdir}" || {
			err="build error"
			return 1
		}
	elif ! istrue ${opt_fetch}; then
		install_pkg_binary_depends "${pkg_binary}" || {
			err="dependency error"
			return 1
		}
	fi

	if istrue ${opt_fetch} || istrue ${opt_build}; then
		result="done"
		return 0
	fi

	if {
		case ${pkg_binary} in
		'')	install_package "${pkg_portdir}" ;;
		*)	install_pkg_binary "${pkg_binary}" ;;
		esac
	}; then
		result="done"
	else
		err="install error"
		return 1
	fi

	set_automatic_flag "${pkg_name}" "${opt_automatic}" || return 1
}

do_replace_config() {
	err=; result=
	local _cur_pkgname

	_cur_pkgname="$1"
	pkg_flavor=

	set_pkginfo_replace "$1" || {
		warn "Skipping '$1'${err:+ - ${err}}."
		result="skipped"
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${_cur_pkgname}' (-> ${pkg_name}) - ignored"
		return 0
	fi

	if istrue ${opt_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config-conditional: %-${#2}s\\r" "$1"
		xtry make_config_conditional "${pkg_portdir}" || {
			err="config-conditional error"
			return 1
		}
		result="done"
	fi

	if istrue ${opt_force_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config: %-${#2}s\\r" "$1"
		xtry make_config "${pkg_portdir}" || {
			err="config error"
			return 1
		}
		result="done"
	fi

}

do_replace() {
	local _deps _pkg_tmpdir _old_pkg
	local _cur_pkgname _cur_origin _origin _automatic_flag
	local _X

	err=; result=
	pkg_flavor=

	if ! isempty "${failed_pkgs}" && ! istrue ${opt_keep_going}; then
		get_depend_pkgnames '_deps' "$1"
		for _X in ${_deps}; do
			case " ${failed_pkgs} " in
			*\ ${_X%-*}\ *)
				info "Skipping '$1' because a requisite package '$X' failed"
				result="skipped"
				return 0 ;;
			esac
		done
	fi

	_cur_pkgname="$1"

	set_pkginfo_replace "$1" || {
		warn "Skipping '$1'${err:+ - ${err}}."
		result="skipped"
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${_cur_pkgname}' (-> ${pkg_name}) - ignored"
		return 0
	fi

	case ${pkg_name} in
	"${_cur_pkgname}")
		if istrue ${opt_force}; then
			info "Reinstalling '${pkg_name}'"
		else
			warn "No need to replace '${_cur_pkgname}'. (specify -f to force)"
			return 0
		fi ;;
	*)	info "Replacing '${_cur_pkgname}' with '${pkg_name}'" ;;
	esac

	if istrue ${opt_noexecute}; then
		result="done"
		return 0
	elif istrue ${opt_interactive}; then
		prompt_yesno || return 0
	fi

	do_logging=${opt_log_prefix:+"${opt_log_prefix}${pkg_name}.log"}

	if isempty ${pkg_binary} && has_config 'USE_PKGS'; then
		if fetch_package "${pkg_name}"; then
			find_package 'pkg_binary' "${pkg_name}" || return 1
		else
			case ${opt_use_packages} in
			1)	warn "Using the source instead of the binary package." ;;
			*)	err="package not found"; return 1 ;;
			esac
		fi
	fi

	if isempty ${pkg_binary}; then
		load_upgrade_vars "${_cur_pkgname}"
		build_package "${pkg_portdir}" || {
			err="build error"
			return 1
		}
	elif ! istrue ${opt_fetch}; then
		install_pkg_binary_depends "${pkg_binary}" || {
			err="dependency error"
			return 1
		}
	fi

	if istrue ${opt_fetch} || istrue ${opt_build}; then
		result="done"
		return 0
	fi

	_pkg_tmpdir="${tmpdir}/${_cur_pkgname}"

	find_package '_old_pkg' "${_cur_pkgname}" ||
		_old_pkg="${_pkg_tmpdir}/${_cur_pkgname}${PKG_BINARY_SUFX}"

	if ! {
		create_dir "${_pkg_tmpdir}" &&
		backup_package "${_cur_pkgname}" "${_old_pkg}" &&
		preserve_libs "${_cur_pkgname}"
		_automatic_flag=$(${PKG_QUERY} '%a' ${_cur_pkgname})
		get_origin_from_pkgname '_cur_origin' ${_cur_pkgname}
	}; then
		err="backup error"
		try rm -rf "${_pkg_tmpdir}"
		return 1
	fi

	if deinstall_package "${_cur_pkgname}"; then
		if {
			case ${pkg_binary} in
			'')
				get_pkgname_from_portdir 'pkg_name' "${pkg_portdir}" &&
					install_package "${pkg_portdir}" ;;
			*)	install_pkg_binary "${pkg_binary}" ;;
			esac
		}; then
			result="done"
			set_automatic_flag "${pkg_name}" "${_automatic_flag}" || return 1
		else
			err="install error"
			restore_package "${_old_pkg}" || {
				warn "Failed to restore the old version," \
				"please reinstall '${_old_pkg}' manually."
				return 1
			}
			set_automatic_flag "${_cur_pkgname}" "${_automatic_flag}" || return 1
		fi
	else
		err="deinstall error"
	fi

	process_package "${_old_pkg}" ||
		warn "Failed to keep the old version."
	clean_libs ||
		warn "Failed to remove the preserved shared libraries."
	try rm -rf "${_pkg_tmpdir}" ||
		warn "Couldn't remove the working direcotry."

	case ${result} in
	done)
		get_origin_from_pkgname '_origin' ${pkg_name}
		if [ ${_cur_origin} != ${_origin} ]; then
			info "Replacing dependencies: '${_cur_origin}' -> '${_origin}'"
			${PKG_SET} -y -o ${_cur_origin}:${_origin} || return 1
		else
			return 0
		fi
		;;
	*)	return 1 ;;
	esac
}

do_version() {
	err=; pkg_name=; pkg_origin=

	printf "\\r%-$(tput co)s\\r" "--->  Checking version: $1"

	if set_pkginfo_replace "$1"; then
		case ${pkg_name} in
		"$1")	return 0 ;;
		esac
		has_config 'IGNORE' && err="held"
	elif isempty "${pkg_name}"; then
		return 0
	else
		pkg_name=; : ${err:=skipped}
	fi

	printf "\\r%-$(tput co)s\\r" " "

	echo "${err:+[${err}] }$1${pkg_name:+ -> ${pkg_name}}${pkg_origin:+ (${pkg_origin})}"
}

main() {
	local _ARG _ARGV _jobs _pids _cnt _X

	init_variables
	init_options
	parse_options ${1+"$@"}
	shift $((optind-1))

	load_config "%%ETCDIR%%/pkg_replace.conf"

	isempty ${PKG_REPLACE-} || parse_options ${PKG_REPLACE}

	if istrue ${opt_all} || { istrue ${opt_version} && ! istrue $#; }; then
		set -- '*'
		opt_depends=0
		opt_required_by=0
	elif ! istrue $#; then
		usage
	fi

	parse_args ${1+"$@"}

	if ! isempty ${opt_exclude}; then
		_ARGV=
		for _ARG in ${install_pkgs}; do
			for _X in ${opt_exclude}; do
				case "|${_ARG}|${_ARG##*/}|" in
					*\|${_X}\|*)	continue 2 ;;
				esac
			done
			_ARGV="${_ARGV} ${_ARG}"
		done
		install_pkgs=${_ARGV}

		_ARGV=
		for _ARG in ${upgrade_pkgs}; do
			for _X in ${opt_exclude}; do
				case "|${_ARG}|${_ARG%-*}|" in
					*\|${_X}\|*)	continue 2 ;;
				esac
			done
			_ARGV="${_ARGV} ${_ARG}"
		done
		upgrade_pkgs=${_ARGV}
	fi

	if isempty ${install_pkgs} && isempty ${upgrade_pkgs}; then
		exit 1
	fi

	istrue ${opt_use_packages} && USE_PKGS='*'

	if istrue ${opt_version}; then
		_jobs=0
		_pids=
		for _ARG in ${upgrade_pkgs}; do
			while [ ${_jobs} -ge ${opt_maxjobs} ]; do
				_jobs=$(($(ps -p ${_pids} 2>/dev/null | wc -l)-1))
				[ ${_jobs} -lt 0 ] && _jobs=0
			done
			( do_version "${_ARG}" ) &
			_pids="${_pids} $!"
			_jobs=$(($(ps -p ${_pids} 2>/dev/null | wc -l)-1))
			[ ${_jobs} -lt 0 ] && _jobs=0
		done
		wait
		tput cd
	else
		create_tmpdir && init_result || exit 1

		set_signal_int='set_result "${_ARG:-XXX}" failed "aborted"'
		set_signal_exit='show_result; write_result "${opt_result}"; clean_tmpdir'
		set_signal_handlers

		istrue ${opt_omit_check} || pkg_sort 'upgrade_pkgs' ${upgrade_pkgs}

		# config
		(istrue ${opt_config} || istrue ${opt_force_config}) && {
			set -- ${install_pkgs}
			_cnt=0
			_ARGV=
			for _ARG in ${1+"$@"}; do
				do_install_config "${_ARG}" "${_ARGV}" || {
					warn "Fix the problem and try again."
					result="failed"
					failed_pkgs="${failed_pkgs} ${pkg_name%-*}"
				}
				_ARGV=${_ARG}
			done
			set -- ${upgrade_pkgs}
			_cnt=0
			_ARGV=
			for _ARG in ${1+"$@"}; do
				do_replace_config "${_ARG}" "${_ARGV}" || {
					warn "Fix the problem and try again."
					result="failed"
					failed_pkgs="${failed_pkgs} ${pkg_name%-*}"
				}
				_ARGV=${_ARG}
			done
			tput cd
		}

		# install
		set -- ${install_pkgs}
		_cnt=0

		for _ARG in ${1+"$@"}; do
			do_install "${_ARG}" || {
				warn "Fix the problem and try again."
				result="failed"
				failed_pkgs="${failed_pkgs} ${pkg_name%-*}"
			}
			set_result "${_ARG}" "${result:-ignored}" "${err}"

			eval info \"** [$((_cnt+=1))/$#] - ${log_summary}\"
		done

		# upgrade
		set -- ${upgrade_pkgs}
		_cnt=0
		do_upgrade=1

		for _ARG in ${1+"$@"}; do
			do_replace "${_ARG}" || {
				warn "Fix the problem and try again."
				result="failed"
				failed_pkgs="${failed_pkgs} ${pkg_name%-*}"
			}
			set_result "${_ARG}" "${result:-ignored}" "${err}"

			eval info \"** [$((_cnt+=1))/$#] - ${log_summary}\"
		done

		isempty ${failed_pkgs} || exit 1
	fi

	exit 0
}

IFS=' 
'

case ${0##*/} in
pkg_replace)	main ${1+"$@"} ;;
esac
