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


PKG_REPLACE_VERSION=20230105
PKG_REPLACE_CONFIG=FreeBSD

usage() {
	cat <<-EOF
usage: ${0##*/} [-abBcCddfFhiJknNOpPPrRRuvVwW] [--automatic]
                [--batch] [--clean] [--cleanup] [--config]
                [--debug] [--force-config] [--noclean] [--nocleanup]
                [--nocleandeps] [--noconfig] [--version]
                [-j jobs] [-l file] [-L log-prefix]
                [-m make_args] [-M make_env] [-x pkgname]
                [[pkgname[=package]] [package] [pkgorigin] ...]
EOF
	exit 0
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
	opt_cleandeps=1
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
	: ${PKG_REPLACE_DB_DIR=${PKG_REPLACE_DB_DIR:-"/var/tmp/pkg_replace"}}
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
	PKG_RQUERY="${PKG_BIN} rquery"
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
		force-config)	opt_force_config=1 ;;
		noclean)	opt_beforeclean=0 ;;
		nocleanup)	opt_afterclean=0 ;;
		nocleandeps)	opt_cleandeps=0 ;;
		noconfig)	opt_noconf=1 ;;
		version)	echo ${PKG_REPLACE_VERSION}; exit 0 ;;
		*)	usage ;;
		esac
	done

	while getopts abBcCdfFhiIJj:kl:L:m:M:nNOpPrRuvVwWx: X; do
		case $X in
		a)	opt_all=1 ;;
		b)	opt_keep_backup=1 ;;
		B)	opt_backup=0 ;;
		c)	opt_config=1 ;;
		C)	opt_force_config=1 ;;
		d)	opt_depends=$((opt_depends+1)) ;;
		f)	opt_force=1 ;;
		F)	opt_fetch=1 ;;
		h)	usage ;;
		i)	opt_interactive=1 ;;
		J)	opt_build=1 ;;
		j)	opt_maxjobs=$( [ ${OPTARG} -ge 1 ] 2> /dev/null && echo ${OPTARG} || sysctl -n hw.ncpu ) ;;
		k)	opt_keep_going=1 ;;
		l)	opt_result=$(expand_path ${OPTARG}) ;;
		L)	opt_log_prefix=$(expand_path ${OPTARG}) ;;
		m)	opt_make_args="${opt_make_args} ${OPTARG}" ;;
		M)	opt_make_env="${opt_make_env} ${OPTARG}" ;;
		n)	opt_noexecute=1 ;;
		N)	opt_new=1 ;;
		O)	opt_omit_check=1 ;;
		p)	opt_package=1 ;;
		P)	opt_use_packages=$((opt_use_packages+1)) ;;
		r)	opt_required_by=1 ;;
		R)	opt_depends=$((opt_depends+1)) ;;
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
	#istrue ${opt_depends} && opt_omit_check=0
	istrue ${opt_force_config} && opt_config=0
	istrue ${opt_omit_check} && opt_keep_going=1

	optind=$((OPTIND+long_optind))

}

parse_args() {
	local ARG pkg installed_pkg p

	for ARG in ${1+"$@"}; do
		pkg_flavor=; pkg_portdir=; pkg_origin=; pkg=;

		case ${ARG} in
		\\*)	ARG=${ARG#\\} ;;
		?*=*)	pkg=${ARG#*=}; ARG=${ARG%%=*} ;;
		esac

		ARG=${ARG%/}

		case ${ARG} in
		*${PKG_BINARY_SUFX})
			[ ! -e "${ARG}" ] && warn "'${ARG}' does not exist." && continue
			get_installed_pkgname $(get_binary_pkgname "${ARG}") 2>&1 > /dev/null &&
				install_pkgs="${install_pkgs} ${ARG}" && continue
			;;
		*@*/*)	;;
		*/*@*|*/*)
			case ${ARG} in
			*@*)	pkg_flavor=${ARG##*@}; pkg_portdir=${ARG%@*}; pkg_origin=${ARG%@*} ;;
			*)	pkg_flavor=; pkg_portdir=${ARG}; pkg_origin=${ARG} ;;
			esac
			if [ -e "${pkg_portdir}/Makefile" ]; then
				pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
			elif pkg_portdir=$(get_portdir_from_origin ${pkg_origin}); then
				pkg_origin=${pkg_origin}
			else
				warn "No such file or package: ${pkg_portdir}"
				continue
			fi
			ARG=${pkg_origin} ;;
		*)	ARG="${ARG}" ;;
		esac

		if installed_pkg=$(get_installed_pkgname ${ARG}); then
			if ! istrue ${opt_all} && istrue ${opt_depends}; then
				upgrade_pkgs="${upgrade_pkgs} $(get_depend_pkgnames "${installed_pkg}")"
			fi
			upgrade_pkgs="${upgrade_pkgs} ${installed_pkg}"
			if istrue ${opt_required_by}; then
				upgrade_pkgs="${upgrade_pkgs} $(get_require_pkgnames ${installed_pkg})"
			fi
			for p in ${installed_pkg}; do
				replace_pkgs="${replace_pkgs}${pkg:+ ${p}=${pkg}}"
			done
		elif istrue ${opt_new}; then
			if isempty ${pkg_flavor}; then
				install_pkgs="${install_pkgs} ${pkg_origin}"
			else
				install_pkgs="${install_pkgs} ${pkg_origin}@${pkg_flavor}"
			fi
		else
			warn "No such file or package installed: ${ARG}, please try -N option"
			continue
		fi

	done
}

parse_config() {
	local line var val array func X

	[ -r "$1" ] || return 0

	line=0; array=; func=

	while read -r X; do
		line=$((line+1))

		case ${X} in
		''|\#*)	continue ;;
		esac

		case ${func:+function}${array:+array} in
		function)
			func="${func}
${X}"
			case ${X} in
			'}'|'};')
				eval "${func}"
				func= ;;
			esac ;;
		array)
			case ${X} in
			*[\'\"]?*[\'\"]*)
				var=${X#*[\'\"]}
				var=${var%%[\'\"]*}

				case ${X} in
				*=\>*[\'\"]*[\'\"]*)
					val=${X#*=\>*[\'\"]}
					val=${val%[\'\"]*}
					eval ${array}='"${'${array}':+$'${array}'
}${var}=${val}"' ;;
				*)
					eval ${array}='"$'${array}' ${var}"' ;;
				esac ;;
			[\)}]|[\)}]\;)
				array= ;;
			*)
				warn "Syntax error at line ${line}: ${X}"
				return 1 ;;
			esac ;;
		*)
			case ${X} in
			*\(\)|*\(\)*{)
				var=${X%%\(\)*}
				var=${var%${var##*[! ]}}
				func="${X}" ;;
			?*=*)
				var=${X%%=*}
				val=${X#*=} ;;
			*)	var="syntax-error" ;;
			esac

			case ${var} in
			*[!0-9A-Za-z_]*|[0-9]*)
				warn "Syntax error at line ${line}: ${X}"
				return 1 ;;
			esac

			case ${func:+1} in
			1)	continue ;;
			esac

			case ${val} in
			*[\({])	eval ${var}=; array=${var} ;;
			*)	eval ${var}=${val} ;;
			esac ;;
		esac
	done < "$1"
}

config_match() {
	case "|${pkg_name}|${pkg_name%-*}|${pkg_origin}|" in
	*\|$1\|*)	return 0 ;;
	*)	return 1 ;;
	esac
}

has_config() {
	local config X
	eval config=\$$1
	for X in ${config}; do
		if config_match "${X%%=*}"; then
			return 0
		fi
	done
	return 1
}

get_config() {
	local IFS config X
	IFS='
'
	eval config=\$$2
	eval $1=
	for X in ${config}; do
		if config_match "${X%%=*}"; then
			eval $1='"${'$1':+$'$1'${3- }}${X#*=}"'
		fi
	done
}

run_config_script() {
	local command
	get_config 'command' "$1" '; '
	if ! isempty ${command}; then
		info "Executing the $1 command: ${command}"
		( set +efu -- "${2:-${pkg_name-}}" "${3:-${pkg_origin-}}"; eval "${command}" )
	fi
}

run_rc_script() {
	local files file
	files="$(${PKG_QUERY} '%Fp' $1)"
	for file in ${files}; do
		case ${file} in
		*.sample) ;;
		*/etc/rc.d/*)
			if [ -x "${file}" ]; then
				info "Executing '${file} $2'"
				try "${file}" "$2"
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
	${PKG_QUERY} -g '%n-%v' $1 2> /dev/null || return 1
	return 0
}

get_origin_from_pkgname() {
	${PKG_QUERY} '%o' $1 || return 1
	return 0
}

get_pkgname_from_portdir() {
	[ ! -d "$1" ] && return 1
	load_make_vars
	cd $1 && ${PKG_MAKE} -VPKGNAME || return 1
	return 0
}

get_overlay_dir() {
	local overlay pkgname
	for overlay in ${OVERLAYS} ${PORTSDIR}; do
		pkgname=$(get_pkgname_from_portdir ${overlay}/$1)
		[ ${#pkgname} -ge 3 ] || continue
		echo ${overlay} && return 0
	done
	return 1
}

get_portdir_from_origin() {
	local portdir pkgname
	portdir=$(get_overlay_dir $1)/$1
	pkgname=$(get_pkgname_from_portdir ${portdir})
	[ ${#pkgname} -ge 3 ] || return 1
	echo ${portdir} && return 0
}

get_pkgname_from_origin() {
	${PKG_QUERY} '%n-%v' $1 && return 0
	return 1
}

get_depend_pkgnames() {
	local deps X pkgfile
	deps=
	if istrue ${opt_use_packages}; then
		for X in $1; do
			pkgfile=${PKGREPOSITORY}/$X${PKG_BINARY_SUFX}
			if [ -e ${pkgfile} ]; then
				deps="${deps} $(${PKG_QUERY} -F ${pkgfile} '%dn-%dv')"
			else
				install_pkgs="${install_pkgs} $X"
			fi
		done
	else
		deps=$(${PKG_QUERY} '%dn-%dv' $1 | sort -u)
		[ ${opt_depends} -ge 2 ] && {
			load_make_vars;
			deps=${deps}' '$(get_strict_depend_pkgnames "$1");
		}
	fi
	echo ${deps} | tr ' ' '\n' | sort -u
	return 0
}

get_strict_depend_pkgnames() {
	local deps dels cut_deps
	local pkg pkgdeps_file
	local jobs pids

	deps=; dels=; cut_deps=;

	jobs=0
	pids=
	for pkg in $1; do
		while [ $jobs -ge ${opt_maxjobs} ]; do
			jobs=$(($(ps -p ${pids} 2>/dev/null | wc -l)-1))
			[ ${jobs} -lt 0 ] && { jobs=0; pids=; }
		done
		get_strict_depend_pkgs ${pkg} &
		pids="${pids} $!"
		jobs=$(($(ps -p ${pids} 2>/dev/null | wc -l)-1))
		[ ${jobs} -lt 0 ] && { jobs=0; pids=; }
	done
	wait

	for pkg in $1; do
		pkgdeps_file=${PKG_REPLACE_DB_DIR}/${pkg}.deps
		if [ -f ${pkgdeps_file} ]; then
			if [ -s ${pkgdeps_file} ]; then
				deps=${deps}' '$(cat ${pkgdeps_file})
				deps=$(echo ${deps} | tr ' ' '\n' | sort -u)
			else
				dels=${dels}' '${pkg}
			fi
		fi
	done

	deps=$(echo ${deps} | tr ' ' '\n' | sort -u)
	dels=$(echo ${dels} | tr ' ' '\n' | sort -u)

	for pkg in ${deps}; do
		case ' '${dels}' ' in
		*\ ${pkg}\ *)	continue ;;
		*)	cut_deps=${cut_deps}' '${pkg} ;;
		esac
	done

	echo ${cut_deps}

	return 0
}

get_strict_depend_pkgs(){
	local origin origins pkgdeps_files
	pkgdeps_file=${PKG_REPLACE_DB_DIR}/$1.deps
	istrue ${opt_cleandeps} || { [ -e ${pkgdeps_file} ] && return 0; }
	origin=$(get_origin_from_pkgname $1) || return 0
		#{ warn "'$1' has no origin! Check packages dependencies, e.g., \`pkg check -adn\`." && return 0; }
	origins=$(cd $(get_portdir_from_origin ${origin}) && ${PKG_MAKE} -V BUILD_DEPENDS -V PATCH_DEPENDS -V FETCH_DEPENDS -V EXTRACT_DEPENDS -V PKG_DEPENDS | tr ' ' '\n' | cut -d: -f2 | sort -u)
	if [ -z "${origins}" ]; then
		touch ${pkgdeps_file}
	else
		get_pkgname_from_origin "${origins}" | tr ' ' '\n' | sort -u > ${pkgdeps_file}
	fi
}

get_require_pkgnames() {
	${PKG_QUERY} '%rn-%rv' $1 | sort -u || return 1
	return 0
}

get_binary_pkgname() {
	${PKG_QUERY} -F $1 '%n-%v' || return 1
	return 0
}

get_binary_origin() {
	${PKG_QUERY} -F $1 '%o' || return 1
	return 0
}

get_binary_flavor(){
	${PKG_QUERY} -F $1 '%At %Av' | grep flavor | cut -d' ' -f 2
	return 0
}

get_depend_binary_pkgnames() {
	${PKG_QUERY} -F $1 '%dn-%dv:%do' || return 1
	return 0
}

pkg_sort() {
	local pkgs pkg cnt dep_list sorted_dep_list

	case $# in
	0|1)	upgrade_pkgs=$@; return 0
	esac

	pkgs=$@

	# check dependencies
	echo -n 'Checking dependencies'
	dep_list= ; cnt=0
	while : ; do
		echo -n '.'
		dep_list=${dep_list}$(echo ${pkgs} | tr ' ' '\n' | sed "s/^/${cnt}:/")' '
		pkgs=$(get_depend_pkgnames "${pkgs}")
		[ -z "${pkgs}" ] && echo 'done.' && break
		cnt=$((cnt+1))
	done

	sorted_dep_list=$(echo ${dep_list} | tr ' ' '\n' | sort -u | sort -t: -k 1nr -k 2 | cut -d: -f 2)
	# delete duplicate package
	dep_list=
	for pkg in ${sorted_dep_list}; do
		case " ${dep_list} " in
		*\ ${pkg}\ *)	continue ;;
		*)	dep_list="${dep_list}${pkg} " ;;
		esac
	done

	[ ${opt_depends} -ge 2 ] || {
		# only pkgs
		pkgs=$(echo $@ | tr '\n' ' ')
		sorted_dep_list=${dep_list}
		dep_list=
		for pkg in ${sorted_dep_list}; do
			case " ${pkgs} " in
			*\ ${pkg}\ *)	dep_list="${dep_list}${pkg} " ;;
			*)	continue ;;
			esac
		done
	}

	upgrade_pkgs=${dep_list}

	return 0
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

remove_dir() {
	if [ -d "$1" ]; then
		try rm -rf "$1" || {
			warn "Couldn't remove the directory: $1";
			return 1;
		}
	fi
}

expand_path() {
	case "$1" in
	[!/]*)	echo "${PWD:-`pwd`}/${1#./}" ;;
	*)	echo $1 ;;
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
	local build_args

	build_args=

	if istrue ${opt_fetch}; then
		build_args="-DBATCH checksum"
		info "Fetching '$1'"
	else
		istrue ${opt_package} && build_args="DEPENDS_TARGET=install"
		istrue ${opt_batch} && build_args="${build_args} -DBATCH"
		info "Building '$1'${PKG_MAKE_ARGS:+ with make flags: ${PKG_MAKE_ARGS}}"
	fi

	cd $1 || return 1

	if ! istrue ${opt_fetch}; then
		run_config_script 'BEFOREBUILD'
		if istrue ${opt_beforeclean}; then
			clean_package $1 || return 1
		fi
	fi

	xtry ${PKG_MAKE} ${build_args} || return 1

	(istrue ${opt_package} && xtry ${PKG_MAKE} package || return 1) || return 0

}

set_automatic_flag() {
	${PKG_SET} -y -A $2 $(${PKG_QUERY} '%n-%v' $1) 2> /dev/null || return 1
	return 0
}

install_pkg_binary_depends() {
	local dep_name dep_origin installed_pkg X dep_pkgs

	info "Installing dependencies for '$1'"

	dep_pkgs=$(get_depend_binary_pkgnames $1) || return 1
	for X in ${dep_pkgs}; do
		dep_name=${X%:*}
		dep_origin=${X##*:}
		if {
			installed_pkg=$(get_installed_pkgname ${dep_name%-*}) ||
				installed_pkg=$(get_pkgname_from_origin ${dep_origin})
		}; then
			info " Required installed package: ${dep_name} - installed"
		else
			info " Required installed package: ${dep_name} - not installed"
			{ opt_build=0; do_install "${dep_origin}" && [ "${result}" = "done" ]; } ||
			{
				warn "Failed to install '${dep_origin}'"
				return 1
			}
			set_automatic_flag ${dep_origin} '1' || return 1
			info "Returning to install of '$1'"
			isempty ${do_upgrade} && set_pkginfo_replace $1 || set_pkginfo_install $1
		fi
	done
}

install_pkg_binary() {
	local install_args
	install_args=
	info "Installing '$1'"
	istrue ${opt_force} && install_args="-f"
	xtry ${PKG_ADD} ${install_args} $1 || return 1
	run_config_script 'AFTERINSTALL'
}

install_package() {
	local install_args
	install_args=

	info "Installing '$1'"

	istrue ${opt_force} && install_args="-DFORCE_PKG_REGISTER"
	istrue ${opt_batch} && install_args="${_install_args} -DBATCH"

	cd $1 || return 1
	xtry ${PKG_MAKE} ${install_args} reinstall || return 1
	if istrue ${opt_afterclean}; then
		clean_package $1
	fi

	run_config_script 'AFTERINSTALL'
}

deinstall_package() {
	local deinstall_args
	deinstall_args=

	istrue ${do_upgrade} || istrue ${opt_force} && deinstall_args="-f"
	deinstall_args="${deinstall_args} -y" || \
		(istrue ${opt_verbose} && deinstall_args="${deinstall_args} -v")

	info "Deinstalling '$1'"

	if [ ! -w "${PKG_DBDIR}" ]; then
		warn "You do not own ${PKG_DBDIR}."
		return 1
	fi

	run_config_script 'BEFOREDEINSTALL' "$1"

	try ${PKG_DELETE} ${deinstall_args} $1 || return 1
}

clean_package() {
	local clean_args
	clean_args=

	info "Cleaning '$1'"

	cd $1 || return 1

	try ${PKG_MAKE} ${clean_args} clean || return 1
}

do_fetch() {
	local fetch_cmd fetch_args fetch_path

	fetch_path=${2:-${1##*/}}
	fetch_cmd=${PKG_FETCH%%[$IFS]*}
	fetch_args=${PKG_FETCH#${fetch_cmd}}

	case ${fetch_cmd##*/} in
	curl|fetch|ftp|axel)	fetch_args="${fetch_args} -o ${fetch_path}" ;;
	wget)	fetch_args="${fetch_args} -O ${fetch_path}" ;;
	esac

	case ${fetch_path} in
	*/*)	cd ${fetch_path%/*}/ || return 1 ;;
	esac

	try ${fetch_cmd} ${fetch_args} $1

	if [ ! -s "${fetch_path}" ]; then
		warn "Failed to fetch: $1"
		try rm -f "${fetch_path}"
		return 1
	fi
}

fetch_package() {
	local pkg uri uri_path

	pkg=$1${PKG_BINARY_SUFX}
	if [ -e "${PKGREPOSITORY}/${pkg}" ]; then
		return 0
	elif ! create_dir ${PKGREPOSITORY} || [ ! -w "${PKGREPOSITORY}" ]; then
		warn "You do not own ${PKGREPOSITORY}."
		return 1
	fi

	load_env_vars

	if ! isempty ${PACKAGESITE-}; then
		uri="${PACKAGESITE}${pkg}"
	else
		uri_path="/$(${PKG_CONFIG} abi)/latest/All/"
		uri="${PACKAGEROOT}${uri_path}${pkg}"
	fi

	do_fetch "${uri}" "${PKGREPOSITORY}/${pkg}" || return 1
}

find_package() {
	local pkgfile
	pkgfile="${PKGREPOSITORY}/$1${PKG_BINARY_SUFX}"
	if [ -e "${pkgfile}" ]; then
		echo ${pkgfile}
		return 0
	else
		return 1
	fi
}

backup_package() {
	if istrue ${opt_backup} && [ ! -e "$2" ]; then
		info "Backing up the old version"
		try ${PKG_CREATE} -o ${2%/*} $1 || return 1
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
		install_pkg_binary $1 || return 1
	else
		return 1
	fi
}

restore_file() {
	if [ -e "$1" ] && [ ! -e "$2" ]; then
		info "Restoring the ${1##*/} file"
		try mv -f $1 $2 || return 1
	fi
}

process_package() {
	if istrue ${opt_keep_backup} && [ -e "$1" ] && [ ! -e "${PKG_BACKUP_DIR}/${1##*/}" ]; then
		info "Keeping the old version in '${PKG_BACKUP_DIR}'"
		create_dir ${PKG_BACKUP_DIR} || return 1
		try mv -f $1 ${PKG_BACKUP_DIR} || return 1
	fi
}

preserve_libs() {
	local file
	istrue ${opt_preserve_libs} || return 0
	preserved_files=
	for file in $(${PKG_QUERY} '%Fp' $1); do
		case ${file##*/} in
		*.so.[0-9]*|*.so)
			[ -f "${file}" ] && preserved_files="${preserved_files} ${file}" ;;
		esac
	done
	if ! isempty ${preserved_files}; then
		info "Preserving the shared libraries"
		create_dir "${PKGCOMPATDIR}" || return 1
		try cp -af ${preserved_files} ${PKGCOMPATDIR} || return 1
	fi
}

clean_libs() {
	local del_files dest file
	if istrue ${opt_preserve_libs} || isempty ${preserved_files}; then
		return 0
	fi
	info "Cleaning the preserved shared libraries"
	del_files=
	for file in ${preserved_files}; do
		dest=${PKGCOMPATDIR}/${file##*/}
		if [ -e "${dest}" ]; then
			del_files="${del_files} ${dest}"
		else
			info "Keeping ${file} as ${dest}"
		fi
	done
	if ! isempty ${del_files}; then
		try rm -f ${del_files} || return 1
	fi
}

parse_moved() {
	local IFS ret info origin new_origin portdir
	local date why checked X

	ret=$1; eval $1=
	info=$2; eval $2=
	origin=$3; checked=

	IFS='|'
	while X=$(grep "^${origin}|" "${PORTSDIR}/MOVED"); do
		set -- $X
		origin=${1-}; new_origin=${2-}; date=${3-}; why=${4-}

		case "$#:${checked}:" in
		[!4]:*|?:*:${new_origin}:*)
			warn "MOVED may be broken"
			return 1
		esac

		checked="${checked}:${origin}"
		origin=${new_origin}
		eval ${info}='"${why} (${date})"'

		if isempty ${new_origin}; then
			eval ${ret}=removed
			break
		fi

		portdir=$(get_portdir_from_origin ${new_origin})
		! isempty ${portdir} && eval ${ret}=\${new_origin} && break

	done
}

trace_moved() {
	local moved reason

	parse_moved 'moved' 'reason' "$1" || return 1

	case ${moved} in
	'')
		warn "Path is wrong or has no Makefile:"
		return 1 ;;
	removed)
		warn "'$1' has removed from ports tree:"
		warn "    ${reason}"
		return 1 ;;
	*)
		warn "'$1' has moved to '${moved}':"
		warn "    ${reason}"
		pkg_origin=${moved}
		pkg_portdir=$(get_portdir_from_origin ${moved})
		;;
	esac
}

init_result() {
	local X

	log_file="${tmpdir}/${0##*/}.log"
	create_file "${log_file}" || return 1

	for X in ${log_format}; do
		eval cnt_${X#*:}=0
		eval log_sign_${X#*:}=${X%%:*}
		log_summary="${log_summary:+${log_summary}, }\${cnt_${X#*:}} ${X#*:}"
	done
}

set_result() {
	log_length=$((log_length+1))
	eval cnt_$2=$((cnt_$2+1))
	eval 'echo "${log_sign_'$2'} $1${3:+ ($3)}" >> "${log_file}"'
}

show_result() {
	local mask descr X

	mask=
	descr=
	istrue ${log_length} || return 0

	for X in ${log_format}; do
		case ${X#*:} in
		failed)
			istrue ${cnt_failed} || continue ;;
		skipped)
			istrue ${cnt_skipped} || continue ;;
		*)	istrue ${opt_verbose} || continue ;;
		esac
		mask="${mask}${X%%:*}"
		descr="${descr:+${descr} / }${X}"
	done

	if ! isempty ${mask}; then
		info "Listing the results (${descr})"
		while read X; do
			case ${X%% *} in
			["${mask}"])
				echo "        ${X}" ;;
			esac
		done < "${log_file}"
	fi
}

write_result() {
	if ! isempty "$1"; then
		try cp -f "${log_file}" $1 || return 0
	fi
	try rm -f "${log_file}"
}

set_signal_handlers() {
	trap "warn Interrupted.; ${set_signal_int:+${set_signal_int};} exit 1" 1 2 3 15
	trap "${set_signal_exit:--}" 0
}


set_pkginfo_install() {
	case "$1" in
	*${PKG_BINARY_SUFX})
		# match "*.pkg"
		pkg_binary=$1
		pkg_name=$(get_binary_pkgname ${pkg_binary}) ||
			{ warn "'$1' is not a valid package."; return 1; }
		pkg_origin=$(get_binary_origin ${pkg_binary})
		pkg_flavor=$(get_binary_flavor ${pkg_binary})
		pkg_portdir=$(get_portdir_from_origin ${pkg_origin})
		;;
	*/*@*|*/*)
		# match origin@flavor or origin
		case $1 in
		*@*)	pkg_flavor=${1##*@}; pkg_origin=${1%@*}; pkg_portdir=${1%@*} ;;
		*)	pkg_flavor=; pkg_origin=$1; pkg_portdir=$1 ;;
		esac
		if pkg_portdir=$(get_portdir_from_origin ${1}); then
			# match origin
			pkg_origin=${1}
		elif [ -e "${1}/Makefile" ]; then
			# match portdir
			pkg_portdir=$(expand_path ${1})
			pkg_portdir=${pkg_portdir%/}
			get_pkgname_from_portdir ${pkg_portdir} 2>&1 > /dev/null ||
				warn "'${pkg_portdir}' is not portdir!"; return 1
			pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
		else
			warn "'$1' not found."
			return 1
		fi
		pkg_name=$(get_pkgname_from_portdir ${pkg_portdir})
		pkg_binary=${PKGREPOSITORY}/${pkg_name}${PKG_BINARY_SUFX}
		[ -e ${pkg_binary} ] || pkg_binary=
		istrue ${opt_use_packages} || pkg_binary=
		;;
	*)
		# match other
		pkg_name=$1
		pkg_binary=${PKGREPOSITORY}/${pkg_name}${PKG_BINARY_SUFX}
		if istrue ${opt_use_packages} && [ -e ${pkg_binary} ]; then
			# get informations from binary package file.
			pkg_origin=$(get_binary_origin ${pkg_binary})
			pkg_flavor=$(get_binary_flavor ${pkg_binary})
			pkg_portdir=$(get_portdir_from_origin ${pkg_origin})
		else
			[ -e ${pkg_binary} ] || pkg_binary=
			pkg_origin=$(${PKG_RQUERY} -g '%o' ${pkg_name%-*}\*) || return 1
			pkg_portdir=$(get_portdir_from_origin ${pkg_origin}) || return 1
			pkg_flavor=
		fi
		istrue ${opt_use_packages} || pkg_binary=
		;;
	esac
}

set_pkginfo_replace() {
	local X
	pkg_name=$1
	pkg_origin=$(get_origin_from_pkgname ${pkg_name})
	pkg_portdir=$(get_portdir_from_origin ${pkg_origin})
	pkg_binary=

	isempty ${pkg_flavor} &&
		pkg_flavor=$( ${PKG_ANNOTATE} --quiet --show "$1" flavor)

	for X in ${replace_pkgs}; do
		case ${pkg_name} in
		"${X%%=*}")
			# match pkgname=foo, foo is *.pkg, origin@flavor, origin or portdir.
			X=${X#*=} # get information after '='
			case "${X}" in
			*${PKG_BINARY_SUFX})	pkg_binary=${X}; break ;;
			*/*@*|*/*)
				# match origin@flavor, origin or portdir
				case $1 in
				*@*)	pkg_flavor=${X##*@}; pkg_origin=${X%@*}; pkg_portdir=${X%@*} ;;
				*)	pkg_flavor=; pkg_origin=$X; pkg_portdir=$X ;;
				esac
				if pkg_portdir=$(get_portdir_from_origin ${X}); then
					# origin
					pkg_origin=${X}
				elif [ -e "${X}/Makefile" ]; then
					# portdir
					pkg_portdir=$(expand_path ${X})
					pkg_portdir=${pkg_portdir%/}
					get_pkgname_from_portdir ${pkg_portdir} 2>&1 > /dev/null ||
						warn "'${pkg_portdir}' is not portdir!"; return 1
					pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
				else
					warn "'$X' not found."
					return 1
				fi ;;
			.)
				# match relative path '.'
				pkg_portdir=$(expand_path ${X}/)
				pkg_portdir=${pkg_portdir%/}
				get_pkgname_from_portdir ${pkg_portdir} 2>&1 > /dev/null ||
					warn "'${pkg_portdir}' is not portdir!"; return 1
				pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
				;;
			*)
				#match other
				pkg_portdir=$(expand_path ${X})
				pkg_portdir=${pkg_portdir%/}
				get_pkgname_from_portdir ${pkg_portdir} 2>&1 > /dev/null ||
					warn "'${pkg_portdir}' is not portdir!"; return 1
				pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
				;;
			esac
			break ;;
		esac
	done

	if isempty ${pkg_binary}; then
		if isempty ${pkg_origin}; then
			err="not installed or no origin recorded"
			return 1
		elif [ ! -e "${pkg_portdir}/Makefile" ]; then
			trace_moved ${pkg_origin} || { err="removed"; return 1; }
		fi
		pkg_name=$(get_pkgname_from_portdir ${pkg_portdir}) || return 1
	else
		pkg_name=$(get_binary_pkgname ${pkg_binary}) ||
			{ warn "'$1' is not a valid package." ; return 1; }
		pkg_flavor=$(get_binary_flavor ${pkg_binary}) || return 1
	fi
}

make_config_conditional() {
	load_make_vars
	(cd "$1" && ${PKG_MAKE} config-conditional) || return 1
}

make_config() {
	load_make_vars
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
	local cur_pkgname pkg

	case "$1" in
	*/*@*)	pkg_flavor="${1##*@}"; pkg=${1%@*} ;;
	*)	pkg_flavor=; pkg="$1" ;;
	esac

	set_pkginfo_install ${pkg} || {
		warn "Skipping '$pkg'${err:+ - ${err}}."
		result="skipped"
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${pkg_name}' - ignored"
		return 0
	fi

	if ! istrue ${opt_force} && isempty ${pkg_flavor} && cur_pkgname=$(get_pkgname_from_origin ${pkg_origin}); then
		info "Skipping '${pkg_origin}' - '${cur_pkgname}' is already installed"
		return 0
	fi

	info "Installing '${pkg_name}' from '${pkg}'"

	if istrue ${opt_noexecute}; then
		result="done"
		return 0
	elif istrue ${opt_interactive}; then
		prompt_yesno || return 0
	fi

	do_logging=${opt_log_prefix:+"${opt_log_prefix}${pkg_name}.log"}

	if isempty ${pkg_binary} && has_config 'USE_PKGS'; then
		if fetch_package "${pkg_name}"; then
			pkg_binary=$(find_package ${pkg_name}) &&
				info "Found a package of '$1': ${pkg_binary}" ||
					return 1
		else
			case ${opt_use_packages} in
			1)	warn "Using the source instead of the binary package." ;;
			*)	err="package not found"; return 1 ;;
			esac
		fi
	fi

	if isempty ${pkg_binary}; then
		load_make_vars
		build_package ${pkg_portdir} || {
			err="build error"
			return 1
		}
	elif ! istrue ${opt_fetch}; then
		install_pkg_binary_depends ${pkg_binary} || {
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
		'')	install_package ${pkg_portdir} ;;
		*)	install_pkg_binary ${pkg_binary} ;;
		esac
	}; then
		result="done"
	else
		err="install error"
		return 1
	fi

	set_automatic_flag ${pkg_name} ${opt_automatic} || return 1
}

do_replace_config() {
	err=; result=
	local cur_pkgname

	cur_pkgname=$1
	pkg_flavor=

	set_pkginfo_replace "$1" || {
		warn "Skipping '$1'${err:+ - ${err}}."
		result="skipped"
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${cur_pkgname}' (-> ${pkg_name}) - ignored"
		return 0
	fi

	if istrue ${opt_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config-conditional: %-${#2}s\\r" "$1"
		xtry make_config_conditional ${pkg_portdir} || {
			err="config-conditional error"
			return 1
		}
		result="done"
	fi

	if istrue ${opt_force_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config: %-${#2}s\\r" "$1"
		xtry make_config ${pkg_portdir} || {
			err="config error"
			return 1
		}
		result="done"
	fi

}

do_replace() {
	local deps pkg_tmpdir old_pkg
	local cur_pkgname cur_origin origin automatic_flag
	local X

	err=; result=
	pkg_flavor=

	if ! isempty "${failed_pkgs}" && ! istrue ${opt_keep_going}; then
		for X in $(get_depend_pkgnames "$1"); do
			case " ${failed_pkgs} " in
			*\ ${X%-*}\ *)
				info "Skipping '$1' because a requisite package '$X' failed"
				result="skipped"
				return 0 ;;
			esac
		done
	fi

	cur_pkgname=$1

	set_pkginfo_replace $1 || {
		warn "Skipping '$1'${err:+ - ${err}}."
		result="skipped"
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${cur_pkgname}' (-> ${pkg_name}) - ignored"
		return 0
	fi

	case ${pkg_name} in
	"${cur_pkgname}")
		if istrue ${opt_force}; then
			info "Reinstalling '${pkg_name}'"
		else
			warn "No need to replace '${cur_pkgname}'. (specify -f to force)"
			return 0
		fi ;;
	*)	info "Replacing '${cur_pkgname}' with '${pkg_name}'" ;;
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
			pkg_binary=$(find_package ${pkg_name}) &&
				info "Found a package of '$1': ${pkg_binary}" ||
					return 1
		else
			case ${opt_use_packages} in
			1)	warn "Using the source instead of the binary package." ;;
			*)	err="package not found"; return 1 ;;
			esac
		fi
	fi

	if isempty ${pkg_binary}; then
		load_make_vars
		load_upgrade_vars "${cur_pkgname}"
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

	pkg_tmpdir="${tmpdir}/${cur_pkgname}"

	old_pkg=$(find_package ${cur_pkgname}) &&
		info "Found a package of '$1': ${old_pkg}" ||
			old_pkg="${pkg_tmpdir}/${cur_pkgname}${PKG_BINARY_SUFX}"

	if ! {
		create_dir ${pkg_tmpdir} &&
		backup_package ${cur_pkgname} ${old_pkg} &&
		preserve_libs ${cur_pkgname}
		automatic_flag=$(${PKG_QUERY} '%a' ${cur_pkgname})
		cur_origin=$(get_origin_from_pkgname ${cur_pkgname})
	}; then
		err="backup error"
		try rm -rf "${pkg_tmpdir}"
		return 1
	fi

	if deinstall_package "${cur_pkgname}"; then
		if {
			case ${pkg_binary} in
			'')
				pkg_name=$(get_pkgname_from_portdir ${pkg_portdir}) &&
					install_package ${pkg_portdir} ;;
			*)	install_pkg_binary ${pkg_binary} ;;
			esac
		}; then
			result="done"
			set_automatic_flag ${pkg_name} ${automatic_flag} || return 1
		else
			err="install error"
			restore_package "${old_pkg}" || {
				warn "Failed to restore the old version," \
				"please reinstall '${old_pkg}' manually."
				return 1
			}
			set_automatic_flag ${cur_pkgname} ${automatic_flag} || return 1
		fi
	else
		err="deinstall error"
	fi

	process_package "${old_pkg}" ||
		warn "Failed to keep the old version."
	clean_libs ||
		warn "Failed to remove the preserved shared libraries."
	try rm -rf "${pkg_tmpdir}" ||
		warn "Couldn't remove the working direcotry."

	case ${result} in
	done)
		origin=$(get_origin_from_pkgname ${pkg_name})
		if [ ${cur_origin} != ${origin} ]; then
			info "Replacing dependencies: '${cur_origin}' -> '${origin}'"
			${PKG_SET} -y -o ${cur_origin}:${origin} || return 1
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

	if set_pkginfo_replace $1; then
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
	local ARG ARGV jobs pids cnt X

	init_variables
	init_options
	parse_options ${1+"$@"}
	shift $((optind-1))

	load_config "%%ETCDIR%%/pkg_replace.conf"

	isempty ${PKG_REPLACE-} || parse_options ${PKG_REPLACE}

	if istrue ${opt_all} || { istrue ${opt_version} && ! istrue $#; }; then
		set -- '*'
		[ ${opt_depends} -eq 1 ] && opt_depends=0
		opt_required_by=0
	elif ! istrue $#; then
		usage
	fi

	[ ${opt_depends} -ge 2 ] &&
		info "'-dd' or '-RR' option set, this mode is slow!" &&
		create_dir ${PKG_REPLACE_DB_DIR}

	parse_args ${1+"$@"}

	istrue ${opt_omit_check} || istrue ${opt_version} || pkg_sort ${upgrade_pkgs}

	if ! isempty ${opt_exclude}; then
		ARGV=
		for ARG in ${install_pkgs}; do
			for X in ${opt_exclude}; do
				case "|${ARG}|${ARG##*/}|" in
					*\|${X}\|*)	continue 2 ;;
				esac
			done
			ARGV="${ARGV} ${ARG}"
		done
		install_pkgs=${ARGV}
		ARGV=
		for ARG in ${upgrade_pkgs}; do
			for X in ${opt_exclude}; do
				case "|${ARG}|${ARG%-*}|" in
					*\|${X}\|*)	continue 2 ;;
				esac
			done
			ARGV="${ARGV} ${ARG}"
		done
		upgrade_pkgs=${ARGV}
	fi

	if isempty ${install_pkgs} && isempty ${upgrade_pkgs}; then
		exit 1
	fi

	istrue ${opt_use_packages} && USE_PKGS='*'

	if istrue ${opt_version}; then
		jobs=0
		pids=
		for ARG in ${upgrade_pkgs}; do
			while [ ${jobs} -ge ${opt_maxjobs} ]; do
				jobs=$(($(ps -p ${pids} 2>/dev/null | wc -l)-1))
				[ ${jobs} -lt 0 ] && { jobs=0; pids=; }
			done
			do_version "${ARG}" &
			pids="${pids} $!"
			jobs=$(($(ps -p ${pids} 2>/dev/null | wc -l)-1))
			[ ${jobs} -lt 0 ] && { jobs=0; pids=; }
		done
		wait
		tput cd
	else
		create_tmpdir && init_result || exit 1

		set_signal_int='set_result "${ARG:-XXX}" failed "aborted"'
		set_signal_exit='show_result; write_result "${opt_result}"; istrue ${opt_cleandeps} && remove_dir "${PKG_REPLACE_DB_DIR}"; clean_tmpdir'
		set_signal_handlers

		# check installed package
		for X in ${upgrade_pkgs}; do
			get_installed_pkgname $X 2>&1 > /dev/null || {
				install_pkgs="${install_pkgs} $X";
				upgrade_pkgs=$(echo ${upgrade_pkgs} | sed "s| $X | |g");
			}
		done

		# config
		(istrue ${opt_config} || istrue ${opt_force_config}) && {
			set -- ${install_pkgs}
			cnt=0
			ARGV=
			for ARG in ${1+"$@"}; do
				do_install_config "${ARG}" "${ARGV}" || {
					warn "Fix the problem and try again."
					result="failed"
					failed_pkgs="${failed_pkgs} ${pkg_name%-*}"
				}
				ARGV=${ARG}
			done
			tput cd
			set -- ${upgrade_pkgs}
			cnt=0
			ARGV=
			for ARG in ${1+"$@"}; do
				do_replace_config "${ARG}" "${ARGV}" || {
					warn "Fix the problem and try again."
					result="failed"
					failed_pkgs="${failed_pkgs} ${pkg_name%-*}"
				}
				ARGV=${ARG}
			done
			tput cd
		}

		# install
		set -- ${install_pkgs}
		cnt=0

		for ARG in ${1+"$@"}; do
			do_install "${ARG}" || {
				warn "Fix the problem and try again."
				result="failed"
				failed_pkgs="${failed_pkgs} ${pkg_name%-*}"
			}
			set_result "${ARG}" "${result:-ignored}" "${err}"

			eval info \"** [$((cnt+=1))/$#] - ${log_summary}\"
		done

		# upgrade
		set -- ${upgrade_pkgs}
		cnt=0
		do_upgrade=1

		for ARG in ${1+"$@"}; do
			do_replace "${ARG}" || {
				warn "Fix the problem and try again."
				result="failed"
				failed_pkgs="${failed_pkgs} ${pkg_name%-*}"
			}
			set_result "${ARG}" "${result:-ignored}" "${err}"

			eval info \"** [$((cnt+=1))/$#] - ${log_summary}\"
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
