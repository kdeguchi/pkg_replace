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


PKG_REPLACE_VERSION=20240819
PKG_REPLACE_CONFIG=FreeBSD

usage() {
	cat <<-EOF
	usage: ${0##*/} [-abBcCddfFhiJknNOpPPrRRuUvVwW]
	        [--all] [--automatic] [--batch] [--debug] [--version]
	        [--backup-package|--no-backup-package]
	        [--clean|--no-clean] [--cleanup|--no-cleanup]
	        [--makedb] [--cleandeps|--no-cleandeps]
	        [--config|--no-config] [--force-config|--no-force-config]
	        [--verbose|--no-verbose] [--no-backup] [--no-configfile]
	        [-j jobs] [-l file] [-L log-prefix]
	        [-m make_args] [-M make_env] [-t make_target]
	        [-X pkgname ] [-x pkgname]
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
	echo -e "** ${@-}" >&2
}

info() {
	echo -e "--->  ${@-}"
}

prompt_yesno() {
	local X=
	echo -n "${1-OK?} [${2-yes}] " >&2
	read X <&1
	case ${X:-${2-yes}} in
	[Yy][Ee][Ss]|[Yy])	return 0 ;;
	*)	return 1 ;;
	esac
}

init_options() {
	opt_afterclean=1; opt_no_afterclean=
	opt_all=0
	opt_automatic=0
	opt_backup=1; opt_no_backup=
	opt_batch=0
	opt_beforeclean=0; opt_no_beforeclean=
	opt_build=0
	opt_cleandeps=0; opt_no_cleandeps=1
	opt_config=0; opt_no_config=
	opt_depends=0
	opt_exclude=
	opt_force_config=0; opt_no_force_config=
	opt_force=0
	opt_fetch=0
	opt_interactive=0
	opt_keep_backup=0; opt_no_keep_backup=
	opt_keep_going=0
	opt_log_prefix=
	opt_make_args=
	opt_make_env=
	opt_makedb=0
	opt_maxjobs=$(sysctl -n hw.ncpu)
	opt_new=0
	opt_no_configfile=0
	opt_no_execute=0
	opt_omit_check=0
	opt_package=0
	opt_preserve_libs=1
	opt_remove_compat_libs=
	opt_required_by=0
	opt_result=
	opt_target=
	opt_verbose=0; opt_no_verbose=;
	opt_version=0
	opt_unlock=0
	opt_use_packages=0
	do_upgrade=0
	do_logging=
	MAKE_ARGS=
	MAKE_ENV=
	BEFOREBUILD=
	BEFOREDEINSTALL=
	AFTERINSTALL=
	IGNORE=
	USE_PKGS=
	PKG_REPLACE=
}

init_variables() {
	: ${MAKE="make"}
	: ${PORTSDIR="$(${PKG_CONFIG} PORTSDIR)"}
	: ${OVERLAYS="$(cd "${PORTSDIR}" && ${MAKE} -V OVERLAYS)"}
	: ${PKGREPOSITORY="$(${PKG_CONFIG} PKG_CACHEDIR)/All"}
	: ${PACKAGEROOT="https://pkg.FreeBSD.org"}
	: ${PKG_DBDIR="$(${PKG_CONFIG} PKG_DBDIR)"}
	: ${PKG_BINARY_SUFX="$(cd "${PORTSDIR}" && ${MAKE} -V PKG_SUFX -f "Mk/bsd.port.mk")"}
	: ${PKG_FETCH="$(cd "${PORTSDIR}" && ${MAKE} -V FETCH_CMD -f "Mk/bsd.port.mk" || echo fetch)"}
	: ${PKG_BACKUP_DIR=${PKGREPOSITORY}}
	: ${PKG_TMPDIR=${TMPDIR:-"/var/tmp"}}
	: ${PKGCOMPATDIR="%%PKGCOMPATDIR%%"}
	: ${PKG_REPLACE_DB_DIR=${PKG_REPLACE_DB_DIR:-"/var/db/pkg_replace"}}
	export PORTSDIR OVERLAYS PKG_DBDIR PKG_TMPDIR PKG_BINARY_SUFX PKGCOMPATDIR
	tmpdir=
	set_signal_int=
	set_signal_exit=
	optind=1
	log_file=
	log_format='+:done -:ignored *:skipped !:failed #:locked %:subpackage x:removed'
	log_length=0
	log_summary=
	cnt_done=
	cnt_ignored=
	cnt_skipped=
	cnt_failed=
	cnt_locked=
	cnt_subpackage=
	cnt_removed=
	log_sign_done=+
	log_sign_ignored=-
	log_sign_skipped=*
	log_sign_failed=!
	log_sign_locked=#
	log_sign_subpackage=%
	log_sign_removed=x
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
	pkg_unlock=0
}

init_pkgtools() {
	PKG_BIN="pkg-static"
	PKG_ADD="${PKG_BIN} add"
	PKG_ANNOTATE="${PKG_BIN} annotate"
	PKG_CHECK="${PKG_BIN} check"
	PKG_CONFIG="${PKG_BIN} config"
	PKG_CREATE="${PKG_BIN} create"
	PKG_DELETE="${PKG_BIN} delete"
	PKG_INFO="${PKG_BIN} info"
	PKG_LOCK="${PKG_BIN} lock"
	PKG_QUERY="${PKG_BIN} query"
	PKG_RQUERY="${PKG_BIN} rquery"
	PKG_SET="${PKG_BIN} set"
	PKG_UNLOCK="${PKG_BIN} unlock"
}

parse_options() {
	local long_opts= long_optind=0 X=

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
		all)		opt_all=1 ;;
		automatic)	opt_automatic=1 ;;
		backup-package)	opt_keep_backup=1 ;;
		batch)		opt_batch=1 ;;
		config)		opt_config=1 ;;
		clean)		opt_beforeclean=1 ;;
		cleanup)	opt_afterclean=1 ;;
		cleandeps)	opt_no_cleandeps=0; opt_cleandeps=1 ;;
		debug)		set -x ;;
		force-config)	opt_force_config=1 ;;
		makedb)		opt_makedb=1; opt_cleandeps=1 ;;
		no-backup)	opt_no_backup=1; opt_backup=0 ;;
		no-backup-package)	opt_no_keep_backup=1; opt_keep_backup=0 ;;
		no-clean)	opt_no_beforeclean=1; opt_beforeclean=0 ;;
		no-cleanup)	opt_no_afterclean=1; opt_afterclean=0 ;;
		no-cleandeps)	opt_no_cleandeps=1; opt_cleandeps=0 ;;
		no-configfile)	opt_no_configfile=1 ;;
		no-config)	opt_no_config=1; opt_config=0 ;;
		no-force-config)	opt_no_force_config=1; opt_force_config=0 ;;
		no-verbose)	opt_no_verbose=1; opt_verbose=0 ;;
		verbose)	opt_verbose=1 ;;
		version)	echo ${PKG_REPLACE_VERSION}; exit 0 ;;
		*)	echo "This option not found."; usage ;;
		esac
	done

	while getopts abBcCdfFhiJj:kl:L:m:M:nNOpPrRt:uUvVwWx:X: X; do
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
		n)	opt_no_execute=1 ;;
		N)	opt_new=1 ;;
		O)	opt_omit_check=1 ;;
		p)	opt_package=1 ;;
		P)	opt_use_packages=$((opt_use_packages+1)) ;;
		r)	opt_required_by=1 ;;
		R)	opt_depends=$((opt_depends+1)) ;;
		t)	opt_target="${opt_target} ${OPTARG}" ;;
		u)	opt_preserve_libs=0 ;;
		U)	opt_unlock=1 ;;
		v)	opt_verbose=1 ;;
		V)	opt_version=1 ;;
		w)	opt_beforeclean=0 ;;
		W)	opt_afterclean=0 ;;
		x)	opt_exclude="${opt_exclude} ${OPTARG}" ;;
		X)	opt_remove_compat_libs="${opt_remove_compat_libs} ${OPTARG}" ;;
		*)	usage ;;
		esac
	done

	istrue ${opt_no_afterclean} && opt_afterclean=0
	istrue ${opt_no_backup} && opt_backup=0
	istrue ${opt_no_beforeclean} && opt_beforeclean=0
	istrue ${opt_no_config} && opt_config=0
	istrue ${opt_no_force_config} && opt_force_config=0
	istrue ${opt_no_keep_backup} && opt_keep_backup=0
	istrue ${opt_no_verbose} && opt_verbose=0

	istrue ${opt_batch} && { opt_config=0; opt_force_config=0; opt_interactive=0; }
	istrue ${opt_cleandeps} && { opt_no_cleandeps=0; opt_cleandeps=1; }
	istrue ${opt_force_config} && opt_config=0
	istrue ${opt_makedb} && { opt_all=1; opt_depends=2; }
	istrue ${opt_omit_check} && { opt_keep_going=1; opt_depends=0; }

	optind=$((OPTIND+long_optind))

}

parse_args() {
	local ARG= pkg= installed_pkg= p=

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
			get_installed_pkgname $(get_binary_pkgname "${ARG}") > /dev/null 2>&1 &&
				install_pkgs="${install_pkgs} ${ARG}" && continue
			;;
		*@*/*)	;;
		*/*@*|*/*)
			case ${ARG} in
			*@*)	pkg_flavor=${ARG##*@}; pkg_portdir="${ARG%@*}"; pkg_origin="${ARG%@*}" ;;
			*)	pkg_flavor=; pkg_portdir="${ARG}"; pkg_origin="${ARG}" ;;
			esac
			if [ -e "${pkg_portdir}/Makefile" ]; then
				pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
			elif pkg_portdir=$(get_portdir_from_origin ${pkg_origin}); then
				pkg_origin=${pkg_origin}
			elif pkg_name=$(get_pkgname_from_origin ${pkg_origin}); then
				pkg_portdir=$(get_portdir_from_origin ${pkg_origin})
			else
				warn "No such file or package: ${pkg_portdir}"
				continue
			fi
			if isempty ${pkg_flavor}; then
				ARG=${pkg_origin}
			else
				ARG=${pkg_origin}@${pkg_flavor}
			fi
			;;
		*)	ARG="${ARG}" ;;
		esac

		if installed_pkg=$(get_installed_pkgname ${ARG}); then
			if ! istrue ${opt_all} && istrue ${opt_depends}; then
				upgrade_pkgs="${upgrade_pkgs} $(get_depend_pkgnames "${installed_pkg}")"
			fi
			upgrade_pkgs="${upgrade_pkgs} ${installed_pkg}"
			if istrue ${opt_required_by}; then
				upgrade_pkgs="${upgrade_pkgs} $(${PKG_QUERY} '%rn-%rv' ${installed_pkg} | sort -u)"
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
	local line=0 var= val= array= func= X=

	[ -r "$1" ] || return 0

	while read -r X; do
		line=$((line+1))

		case $X in
		''|\#*)	continue ;;
		esac

		case ${func:+function}${array:+array} in
		function)
			func="${func}
$X"
			case $X in
			'}'|'};')
				eval "${func}"
				func= ;;
			esac ;;
		array)
			case $X in
			*[\'\"]?*[\'\"]*)
				var=${X#*[\'\"]}
				var=${var%%[\'\"]*}

				case $X in
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
			case $X in
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
	local config= X=
	eval config=\$$1
	for X in ${config}; do
		if config_match "${X%%=*}"; then
			return 0
		fi
	done
	return 1
}

get_config() {
	local config= X=
	local IFS='
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
	local command=
	get_config 'command' "$1" '; '
	if ! isempty ${command}; then
		info "Executing the $1 command: ${command}"
		( set +efu -- "${2:-${pkg_name-}}" "${3:-${pkg_origin-}}"; eval "${command}" )
	fi
}

run_rc_script() {
	local file=
	for file in $(${PKG_QUERY} '%Fp' $1); do
		case "${file}" in
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
	if ! isempty ${1-} && ! istrue ${opt_no_configfile}; then
		istrue ${opt_verbose} && info "Loading $1"
		parse_config "$1" || {
			warn "Fatal error in $1."
			exit 1
		}
	fi
}

load_make_vars() {
	get_config PKG_MAKE_ARGS MAKE_ARGS
	PKG_MAKE_ARGS="${opt_make_args:+${opt_make_args} }${PKG_MAKE_ARGS}"
	case "${PKG_MAKE_ARGS}" in
	*FLAVOR=*)
		pkg_flavor=${PKG_MAKE_ARGS##*FLAVOR=}; pkg_flavor=${pkg_flavor% *} ;;
	esac
	! isempty "${pkg_flavor}" && PKG_MAKE_ARGS="${PKG_MAKE_ARGS} FLAVOR=${pkg_flavor}"
	get_config PKG_MAKE_ENV MAKE_ENV
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
	${PKG_QUERY} -g '%n-%v' $1 || return 1
	return 0
}

get_origin_from_pkgname() {
	${PKG_QUERY} -g '%o' $1 || return 1
	return 0
}

get_flavor() {
	${PKG_QUERY} -g '%At %Av' $1 | grep flavor | cut -d' ' -f 2 || return 1
	return 0
}

get_pkgname_from_portdir() {
	local pkgname=
	[ -d "$1" ] || return 1
	load_make_vars
	pkgname=$( cd "$1" && ${PKG_MAKE} -V PKGNAME ) || return 1
	case ${pkgname} in
	''|-)	return 1 ;;
	*)	echo ${pkgname}; return 0 ;;
	esac
}

get_overlay_dir() {
	local overlay=
	local IFS='	 
'
	for overlay in ${OVERLAYS} ${PORTSDIR}; do
		get_pkgname_from_portdir ${overlay}/$1 > /dev/null 2>&1 || continue
		echo ${overlay} && return 0
	done
	return 1
}

get_portdir_from_origin() {
	local portdir=
	portdir="$(get_overlay_dir "$1")/$1" && echo ${portdir} && return 0
	return 1
}

get_pkgname_from_origin() {
	${PKG_QUERY} -g '%n-%v' $1 || return 1
	return 0
}

get_depend_pkgnames() {
	local deps= X= pkgfile=
	if istrue ${opt_use_packages}; then
		for X in $1; do
			pkgfile="${PKGREPOSITORY}/$X${PKG_BINARY_SUFX}"
			if [ -e ${pkgfile} ]; then
				deps="${deps} $(${PKG_QUERY} -F "${pkgfile}" '%dn-%dv')"
			else
				install_pkgs="${install_pkgs} $X"
			fi
		done
	else
		deps=$(${PKG_QUERY} '%dn-%dv' $1 | sort -u)
		[ ${opt_depends} -ge 2 ] && {
			deps=${deps}' '$(get_strict_depend_pkgnames "$1");
		}
	fi
	echo ${deps} | tr '[:space:]' '\n' | sort -u
	return 0
}

get_strict_depend_pkgnames() {
	local deps= dels= cut_deps=
	local origin= pkgdeps_file=
	local jobs=0 pids=
	local origins=$(get_origin_from_pkgname "$1")

	for origin in ${origins}; do
		pkgdeps_file="${PKG_REPLACE_DB_DIR}/${origin%/*}_${origin#*/}.deps"
		while [ $jobs -ge ${opt_maxjobs} ]; do
			jobs=$(($(ps -p ${pids} 2>/dev/null | wc -l)-1))
			[ ${jobs} -lt 0 ] && { jobs=0; pids=; }
		done
		get_strict_depend_pkgs ${origin} ${pkgdeps_file} &
		pids="${pids} $!"
		jobs=$(($(ps -p ${pids} 2>/dev/null | wc -l)-1))
		[ ${jobs} -lt 0 ] && { jobs=0; pids=; }
	done
	wait

	for origin in ${origins}; do
		pkgdeps_file="${PKG_REPLACE_DB_DIR}/${origin%/*}_${origin#*/}.deps"
		if [ -s "${pkgdeps_file}" ]; then
			deps=${deps}' '$(cat "${pkgdeps_file}")
		else
			dels=${dels}' '${origin}
		fi
	done

	deps=$(echo ${deps} | tr '[:space:]' '\n' | sort -u)
	dels=$(echo ${dels} | tr '[:space:]' '\n' | sort -u)

	for origin in ${deps}; do
		case " ${dels} " in
		*[[:space:]]${origin}[[:space:]]*)	continue ;;
		*)	cut_deps=${cut_deps}' '${origin} ;;
		esac
	done

	isempty ${cut_deps} || echo $(get_pkgname_from_origin "${cut_deps}")

	return 0
}

get_strict_depend_pkgs(){
	local pkgdeps_file=$2
	local portdir= origins=

	istrue ${opt_cleandeps} || { [ -f ${pkgdeps_file} ] && return 0; }

	portdir=$(get_portdir_from_origin $1)
	[ "${pkgdeps_file}" -nt "${portdir}/Makefile" ] && return 0
	pkg_flavor=$(get_flavor $1)
	load_make_vars
	origins=$(cd "${portdir}" && ${PKG_MAKE} -V BUILD_DEPENDS -V PATCH_DEPENDS -V FETCH_DEPENDS -V EXTRACT_DEPENDS -V PKG_DEPENDS | tr '[:space:]' '\n' | cut -s -d: -f2 | sort -u)

	if [ -z "${origins}" ]; then
		touch "${pkgdeps_file}"
	else
		echo "${origins}" > "${pkgdeps_file}"
	fi
}

get_binary_pkgname() {
	[ -e $1 ] || { warn "No such file '$1'"; return 1; }
	${PKG_QUERY} -F $1 '%n-%v' || return 1
	return 0
}

get_binary_origin() {
	[ -e $1 ] || { warn "No such file '$1'"; return 1; }
	${PKG_QUERY} -F $1 '%o' || return 1
	return 0
}

get_binary_flavor(){
	[ -e $1 ] || { warn "No such file '$1'"; return 1; }
	${PKG_QUERY} -F $1 '%At %Av' | grep flavor | cut -d' ' -f 2
	return 0
}

get_depend_binary_pkgnames() {
	[ -e $1 ] || { warn "No such file '$1'"; return 1; }
	${PKG_QUERY} -F $1 '%dn-%dv:%do' || return 1
	return 0
}

get_lock() {
	local lock=
	lock=$(${PKG_QUERY} '%k' $1) || return 1
	case ${lock} in
	0)	return 1 ;;
	1)	return 0 ;;
	esac
}

get_subpackage() {
	[ -z $(${PKG_ANNOTATE} --show --quiet $1 subpackage) ] && return 1
	return 0
}

pkg_sort() {
	local pkgs= pkg= cnt=0 dep_list= sorted_dep_list=

	case $# in
	0|1)	upgrade_pkgs=$@; return 0
	esac

	pkgs=$@

	# check dependencies
	echo -n 'Checking dependencies' >&2
	while : ; do
		echo -n '.' >&2
		dep_list="${dep_list} $(echo ${pkgs} | tr '[:space:]' '\n' | sed "s/^/${cnt}:/")"
		pkgs=$(get_depend_pkgnames "${pkgs}")
		[ -z "${pkgs}" ] && echo 'done.' >&2 && break
		cnt=$((cnt+1))
	done

	sorted_dep_list=$(echo ${dep_list} | tr '[:space:]' '\n' | sort -u | sort -t: -k 1nr -k 2 | cut -d: -f 2)
	# delete duplicate package
	dep_list=
	for pkg in ${sorted_dep_list}; do
		case " ${dep_list} " in
		*[[:space:]]${pkg}[[:space:]]*)	continue ;;
		*)	dep_list="${dep_list}${pkg} " ;;
		esac
	done

	[ ${opt_depends} -ge 2 ] || {
		# only pkgs
		pkgs=$(echo $@ | tr '[:space:]' ' ')
		sorted_dep_list=${dep_list}
		dep_list=
		for pkg in ${sorted_dep_list}; do
			case " ${pkgs} " in
			*[[:space:]]${pkg}[[:space:]]*)	dep_list="${dep_list}${pkg} " ;;
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
	[!/]*)
		if [ -d "$1" ]; then
			echo $( cd "$1" && pwd ) && return 0
		elif [ -e "$1" ]; then
			echo $( cd $( dirname "$1" ) && pwd )/$( basename "$1" ) && return 0
		else
			warn "'$1' is not found!"; return 1
		fi ;;
	*)	echo $1 ;;
	esac
}

try() {
	local _errno=
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
	local build_args=

	if istrue ${opt_fetch}; then
		build_args="checksum"
		info "Fetching '$1'"
	elif ! isempty ${opt_target}; then
		build_args="${opt_target}"
		info "Do 'make${opt_target}' '$1'"
	else
		istrue ${opt_package} && build_args="DEPENDS_TARGET=install"
		istrue ${opt_batch} && build_args="${build_args} -DBATCH"
		info "Building '$1'${PKG_MAKE_ARGS:+ with make flags: ${PKG_MAKE_ARGS}}"
	fi

	cd "$1" || return 1

	if ! istrue ${opt_fetch}; then
		run_config_script 'BEFOREBUILD'
		if istrue ${opt_beforeclean}; then
			clean_package $1 || return 1
		fi
	fi

	xtry ${PKG_MAKE} ${build_args} || return 1

	istrue ${opt_package} && { xtry ${PKG_MAKE} package || return 1; }

	return 0
}

set_automatic_flag() {
	${PKG_SET} -y -A $2 $(${PKG_QUERY} '%n-%v' $1) 2> /dev/null || return 1
	return 0
}

install_pkg_binary_depends() {
	local dep_name= dep_origin= installed_pkg= X= dep_pkgs=

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
			isempty ${do_upgrade} && set_pkginfo_replace $1 '' || set_pkginfo_install $1
		fi
	done
}

install_pkg_binary() {
	local install_args= pkgname=
	info "Installing '$1'"
	istrue ${opt_force} && install_args="-f"
	xtry ${PKG_ADD} ${install_args} "$1" || return 1
	istrue ${pkg_unlock} && {
		pkgname=${1##*/}; pkgname=${pkgname%${PKG_BINARY_SUFX}}
		${PKG_LOCK} -y "${pkgname}" || return 1
	}
	run_config_script 'AFTERINSTALL'
}

remove_preserved_files() {
	local file=
	! isempty ${preserved_files} && {
		for file in $(${PKG_QUERY} '%Fp' $1); do
			case ${file##*/} in
			*.so.[0-9]*|*.so)
				case " ${preserved_files} " in
				*[[:space:]]${file}[[:space:]]*)
					istrue ${opt_verbose} &&
						info "Remove the same name library: '${PKGCOMPATDIR}/${file##*/}'"
					rm -f ${PKGCOMPATDIR}/${file##*/} ;;
				esac
				;;
			esac
		done
	}
}

install_package() {
	local install_args=

	info "Installing '$1'"

	istrue ${opt_force} && install_args="-DFORCE_PKG_REGISTER"
	istrue ${opt_batch} && install_args="${_install_args} -DBATCH"

	cd "$1" || return 1
	xtry ${PKG_MAKE} ${install_args} reinstall || return 1

	istrue ${pkg_unlock} && ${PKG_LOCK} -y $(get_pkgname_from_portdir $1)
	if istrue ${opt_afterclean}; then
		clean_package $1
	fi

	run_config_script 'AFTERINSTALL'
}

deinstall_package() {
	local deinstall_args=

	istrue ${do_upgrade} || istrue ${opt_force} && deinstall_args="-f"
	deinstall_args="${deinstall_args} -y" ||
		{ istrue ${opt_verbose} && deinstall_args="${deinstall_args} -v"; }

	info "Deinstalling '$1'"

	if [ ! -w "${PKG_DBDIR}" ]; then
		warn "You do not own ${PKG_DBDIR}."
		return 1
	fi

	run_config_script 'BEFOREDEINSTALL' "$1"

	try ${PKG_DELETE} ${deinstall_args} $1 || return 1
}

clean_package() {
	info "Cleaning '$1'"
	cd "$1" || return 1
	try ${PKG_MAKE} clean || return 1
}

do_fetch() {
	local fetch_path=${2:-${1##*/}}
	local fetch_cmd=${PKG_FETCH%%[$IFS]*}
	local fetch_args=${PKG_FETCH#${fetch_cmd}}

	case ${fetch_cmd##*/} in
	curl|fetch|ftp|axel)	fetch_args="${fetch_args} -o ${fetch_path}" ;;
	wget)	fetch_args="${fetch_args} -O ${fetch_path}" ;;
	esac

	case ${fetch_path} in
	*/*)	cd "${fetch_path%/*}/" || return 1 ;;
	esac

	try ${fetch_cmd} ${fetch_args} $1

	if [ ! -s "${fetch_path}" ]; then
		warn "Failed to fetch: $1"
		try rm -f "${fetch_path}"
		return 1
	fi
}

fetch_package() {
	local uri= uri_path=
	local pkg=$1${PKG_BINARY_SUFX}

	if [ -e "${PKGREPOSITORY}/${pkg}" ]; then
		return 0
	elif ! create_dir "${PKGREPOSITORY}" || [ ! -w "${PKGREPOSITORY}" ]; then
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
	local pkgfile="${PKGREPOSITORY}/$1${PKG_BINARY_SUFX}"
	[ -e "${pkgfile}" ] && echo ${pkgfile} && return 0
	return 1
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
	local pkgname=
	if [ -e "$1" ]; then
		info "Restoring the old version"
		install_pkg_binary "$1"
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
	local file=
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
		try cp -af ${preserved_files} "${PKGCOMPATDIR}" || return 1
	fi
}

clean_libs() {
	local del_files= dest= file=
	if istrue ${opt_preserve_libs} || isempty ${preserved_files}; then
		return 0
	fi
	info "Cleaning the preserved shared libraries"
	for file in ${preserved_files}; do
		dest="${PKGCOMPATDIR}/${file##*/}"
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
	local new_origin= portdir=
	local date= why= X=

	local ret=$1; eval $1=
	local info=$2; eval $2=
	local origin=$3; checked=

	local IFS='|'

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

		portdir=$(get_portdir_from_origin ${new_origin%@*})
		! isempty ${portdir} && eval ${ret}=\${new_origin} && break

	done
}

trace_moved() {
	local moved= reason=

	parse_moved 'moved' 'reason' "$1" || return 1

	err=
	case ${moved} in
	'')
		warn "Path is wrong or has no Makefile:"
		err=broken
		return 1 ;;
	removed)
		warn "'$1' has removed from ports tree:"
		warn "    ${reason}"
		err=removed
		return 1 ;;
	*)
		warn "'$1' has moved to '${moved}':"
		warn "    ${reason}"
		pkg_origin=${moved}
		pkg_portdir=$(get_portdir_from_origin ${moved%@*})
		return 0 ;;
	esac
}

init_result() {
	local X=

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
	local mask= descr= X=

	istrue ${log_length} || return 0

	for X in ${log_format}; do
		case ${X#*:} in
		failed)		istrue ${cnt_failed} || continue ;;
		skipped)	istrue ${cnt_skipped} || continue ;;
		locked)		istrue ${cnt_locked} || continue ;;
		removed)	istrue ${cnt_removed} || continue ;;
		subpackage)	istrue ${cnt_subpackage} || continue ;;
		*)		istrue ${opt_verbose} || continue ;;
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
	trap "warn Interrupted.; ${set_signal_int:+${set_signal_int};} exit 1" 1 2 3 9 15
	trap "${set_signal_exit:--}" 0
}


set_pkginfo_install() {
	case "$1" in
	*${PKG_BINARY_SUFX})
		# match "*.pkg"
		pkg_binary="$1"
		pkg_name=$(get_binary_pkgname ${pkg_binary}) ||
			{ warn "'$1' is not a valid package."; return 1; }
		pkg_origin=$(get_binary_origin ${pkg_binary})
		pkg_flavor=$(get_binary_flavor ${pkg_binary})
		pkg_portdir=$(get_portdir_from_origin ${pkg_origin})
		;;
	*/*@*|*/*)
		# match origin@flavor or origin
		case $1 in
		*@*)	pkg_flavor=${1##*@}; pkg_origin="${1%@*}"; pkg_portdir="${1%@*}" ;;
		*)	pkg_flavor=; pkg_origin="$1"; pkg_portdir="$1" ;;
		esac
		if pkg_portdir=$(get_portdir_from_origin "${pkg_origin}"); then
			# match origin
			pkg_origin=${pkg_origin}
		elif [ -e "${pkg_portdir}/Makefile" ]; then
			# match portdir
			pkg_portdir=$(expand_path "${pkg_portdir}")
			pkg_portdir=${pkg_portdir%/}
			get_pkgname_from_portdir "${pkg_portdir}" > /dev/null 2>&1 ||
				{ warn "'${pkg_portdir}' is not portdir!"; return 1; }
			pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
		else
			warn "'$1' not found."
			return 1
		fi
		pkg_name=$(get_pkgname_from_portdir "${pkg_portdir}")
		pkg_binary="${PKGREPOSITORY}/${pkg_name}${PKG_BINARY_SUFX}"
		[ -e ${pkg_binary} ] || pkg_binary=
		istrue ${opt_use_packages} || pkg_binary=
		;;
	*)
		# match other
		pkg_name=$1
		pkg_binary="${PKGREPOSITORY}/${pkg_name}${PKG_BINARY_SUFX}"
		if istrue ${opt_use_packages} && [ -e ${pkg_binary} ]; then
			# get informations from binary package file.
			pkg_origin=$(get_binary_origin "${pkg_binary}")
			pkg_flavor=$(get_binary_flavor "${pkg_binary}")
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
	local X= config=$2
	pkg_name=$1
	pkg_origin=$(get_origin_from_pkgname ${pkg_name})
	pkg_portdir=$(get_portdir_from_origin ${pkg_origin})
	pkg_binary=
	pkg_unlock=0

	if isempty ${pkg_flavor}; then
		pkg_flavor=$(${PKG_ANNOTATE} --quiet --show "$1" flavor)
	fi

	for X in ${replace_pkgs}; do
		case ${pkg_name} in
		${X%%=*})
			# match pkgname=foo, foo is *.pkg, origin@flavor, origin or portdir.
			X=${X#*=} # get information after '='
			case $X in
			*${PKG_BINARY_SUFX})	pkg_binary="${X}"; break ;;
			.|./)
				# match relative path '.'
				pkg_portdir=$(expand_path "${X}/")
				pkg_portdir=${pkg_portdir%/}
				get_pkgname_from_portdir ${pkg_portdir} > /dev/null 2>&1 ||
					{ isempty ${config} && warn "'${pkg_portdir}' is not portdir!"; return 1; }
				pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
				;;
			*/*@*|*/*)
				# match origin@flavor, origin or portdir
				case $X in
				*@*)
					pkg_flavor=${X##*@}; pkg_origin="${X%@*}"
					pkg_portdir=$(expand_path "${X%@*}") ;;
				*)
					pkg_flavor=; pkg_origin="$X"; pkg_portdir=$(expand_path "$X") ;;
				esac
				if get_portdir_from_origin "${pkg_origin}" > /dev/null 2>&1; then
					# origin
					pkg_origin=${pkg_origin}
				elif get_pkgname_from_portdir "${pkg_portdir}" > /dev/null 2>&1; then
					# portdir
					pkg_portdir=$(expand_path "${pkg_portdir}")
					pkg_portdir="${pkg_portdir%/}"
					get_pkgname_from_portdir ${pkg_portdir} > /dev/null 2>&1||
						{ isempty ${config} && warn "'${pkg_portdir}' is not portdir!"; return 1; }
					pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
				else
					isempty ${config} && warn "'$X' not found."
					return 1
				fi ;;
			*)
				#match other
				pkg_portdir=$(expand_path "$X")
				pkg_portdir="${pkg_portdir%/}"
				get_pkgname_from_portdir ${pkg_portdir} > /dev/null 2>&1||
					{ isempty ${config} && warn "'${pkg_portdir}' is not portdir!"; return 1; }
				pkg_origin=${pkg_portdir#${pkg_portdir%/*/${pkg_portdir##*/}}/}
				;;
			esac
			break ;;
		esac
	done

	get_lock ${pkg_name} && ! istrue ${opt_unlock} && err="locked"

	get_subpackage ${pkg_name} && err="subpackage"

	if isempty ${pkg_binary}; then
		if isempty ${pkg_origin}; then
			err="not installed or no origin recorded"
			return 1
		elif [ ! -e "${pkg_portdir}/Makefile" ]; then
			isempty ${config} &&
				trace_moved ${pkg_origin} || { err=removed; return 1; }
		fi
		pkg_name=$(get_pkgname_from_portdir "${pkg_portdir}") || return 1
	else
		pkg_name=$(get_binary_pkgname "${pkg_binary}") ||
			{ isempty ${config} && warn "'$1' is not a valid package." ; return 1; }
		pkg_flavor=$(get_binary_flavor "${pkg_binary}") || return 1
	fi

	if isempty $(cd ${pkg_portdir} && ${MAKE} -V FLAVORS); then
		pkg_flavor=
	fi

}

make_config_conditional() {
	{ cd "$1" && ${PKG_MAKE} config-conditional; } || return 1
}

make_config() {
	{ cd "$1" && ${PKG_MAKE} config; } || return 1
}

do_install_config() {
	err=; result=

	set_pkginfo_install "$1" || {
		#istrue ${opt_verbose} && warn "Skipping '$1'${err:+ - ${err}}."
		result=skipped
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		#istrue ${opt_verbose} && warn "Skipping '${pkg_name}' - ignored"
		result=ignored
		return 0
	fi

	load_make_vars

	if istrue ${opt_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config-conditional: %-${#2}s\\r" "$1" >&2
		xtry make_config_conditional "${pkg_portdir}" || {
			err="config-conditional error"
			return 1
		}
	fi

	if istrue ${opt_force_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config: %-${#2}s\\r" "$1" >&2
		xtry make_config "${pkg_portdir}" || {
			err="config error"
			return 1
		}
	fi
}

do_install() {
	local cur_pkgname= pkg=

	err=; result=

	pkg=${1}

	set_pkginfo_install ${pkg} || {
		info "Skipping '$pkg'${err:+ - ${err}}."
		result=skipped
		return 0
	}

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${pkg_name}' - ignored"
		result=ignored
		return 0
	fi

	load_make_vars

	if ! istrue ${opt_force} && isempty ${pkg_flavor} &&
		cur_pkgname=$(get_pkgname_from_origin ${pkg_origin}); then
		info "Skipping '${pkg_origin}' - '${cur_pkgname}' is already installed"
		return 0
	fi

	info "Installing '${pkg_name}' from '${pkg}'"

	if istrue ${opt_no_execute}; then
		result=done
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

	if istrue ${opt_fetch} || ! isempty ${opt_target} || istrue ${opt_build}; then
		result=done
		return 0
	fi

	if {
		case ${pkg_binary} in
		'')	install_package "${pkg_portdir}" ;;
		*)	install_pkg_binary "${pkg_binary}" ;;
		esac
	}; then
		remove_preserved_files ${pkg_name}
		result=done
	else
		remove_preserved_files ${cur_pkgname}
		err="install error"
		return 1
	fi

	set_automatic_flag ${pkg_name} ${opt_automatic} || return 1
}

do_replace_config() {
	local cur_pkgname=$1 X=

	err=; result=

	pkg_flavor=

	set_pkginfo_replace $1 'config' || {
		#istrue ${opt_verbose} && warn "Skipping '$1'${err:+ - ${err}}."
		result=${err}
		return 0
	}

	if get_lock ${cur_pkgname}; then
		#if istrue ${opt_unlock}; then
		#	istrue ${opt_verbose} && warn "${cur_pkgname} will be unlockd."
		#else
		#	istrue ${opt_verbose} &&
		#		warn "Skipping '${cur_pkgname}' (-> ${pkg_name})${err:+ - ${err}} (specify \`-U ${cur_pkgname%-*}\` to upgrade)"
		#	result=locked
		#	return 0
		#fi
		istrue ${opt_unlock} && { result=locked; return 0; }
	fi

	if get_subpackage ${cur_pkgname}; then
		#istrue ${opt_verbose} &&
		#	warn "Skipping '${cur_pkgname}' (-> ${pkg_name})${err:+ - ${err}}"
		result=subpackage
		return 0
	fi

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		#istrue ${opt_verbose} &&
		#	warn "Skipping '${cur_pkgname}' (-> ${pkg_name}) - ignored"
		result=ignored
		return 0
	fi

	load_make_vars

	if istrue ${opt_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config-conditional: %-${#2}s\\r" "$1" >&2
		xtry make_config_conditional "${pkg_portdir}" || {
			err="config-conditional error"
			return 1
		}
		result=done
	fi

	if istrue ${opt_force_config} && isempty ${pkg_binary}; then
		printf "\\r--->  Executing make config: %-${#2}s\\r" "$1" >&2
		xtry make_config "${pkg_portdir}" || {
			err="config error"
			return 1
		}
		result=done
	fi

}

do_replace() {
	local deps= pkg_tmpdir= old_pkg=
	local cur_pkgname= cur_origin= origin= automatic_flag=
	local X=

	err=; result=; pkg_flavor=

	if ! isempty "${failed_pkgs}" && ! istrue ${opt_keep_going}; then
		for X in $(get_depend_pkgnames "$1"); do
			case " ${failed_pkgs} " in
			*[[:space:]]${X%-*}[[:space:]]*)
				info "Skipping '$1' because a requisite package '$X' failed"
				result=skipped
				return 0 ;;
			esac
		done
	fi

	cur_pkgname=$1

	set_pkginfo_replace $1 '' || {
		info "Skipping '$1'${err:+ - ${err}}."
		result=${err}
		return 0
	}

	load_make_vars

	if get_lock ${cur_pkgname}; then
		if istrue ${opt_unlock}; then
			warn "'${cur_pkgname}' is unlocked."
			pkg_unlock=1
		else
			info "Skipping '${cur_pkgname}' (-> ${pkg_name})${err:+ - ${err}} (specify \`-U ${cur_pkgname%-*}\` to upgrade)"
			result=locked
			pkg_unlock=0
			return 0
		fi
	fi

	if get_subpackage ${cur_pkgname}; then
		info "Skipping '${cur_pkgname}' (-> ${pkg_name})${err:+ - ${err}}"
		result=subpackage
		return 0
	fi

	if ! istrue ${opt_force} && has_config 'IGNORE'; then
		info "Skipping '${cur_pkgname}' (-> ${pkg_name}) - ignored"
		result=ignored
		return 0
	fi

	case ${pkg_name} in
	"${cur_pkgname}")
		if istrue ${opt_force}; then
			info "Reinstalling '${pkg_name}'"
		else
			info "No need to replace '${cur_pkgname}'. (specify -f to force)"
			return 0
		fi ;;
	*)	info "Replacing '${cur_pkgname}' with '${pkg_name}'" ;;
	esac

	if istrue ${opt_no_execute}; then
		result=done
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

	if istrue ${opt_fetch} || ! isempty ${opt_target} || istrue ${opt_build}; then
		result=done
		return 0
	fi

	pkg_tmpdir="${tmpdir}/${cur_pkgname}"

	old_pkg=$(find_package ${cur_pkgname}) &&
		info "Found a package of '$1': ${old_pkg}" ||
			old_pkg="${pkg_tmpdir}/${cur_pkgname}${PKG_BINARY_SUFX}"

	istrue ${opt_unlock} &&
		{ ${PKG_UNLOCK} -y ${cur_pkgname}
			if get_lock ${cur_pkgname}; then
				warn "Unlock '${cur_pkgname} failed!'"
				pkg_unlock=0
			else
				info "Unlock '${cur_pkgname}'"
				pkg_unlock=1
			fi
		}

	if ! {
		create_dir "${pkg_tmpdir}" &&
		backup_package ${cur_pkgname} ${old_pkg} &&
		preserve_libs ${cur_pkgname}
		automatic_flag=$(${PKG_QUERY} '%a' ${cur_pkgname})
		cur_origin=$(get_origin_from_pkgname ${cur_pkgname})
	}; then
		err="backup error"
		remove_dir "${pkg_tmpdir}"
		return 1
	fi

	if deinstall_package "${cur_pkgname}"; then
		if {
			case ${pkg_binary} in
			'')
				pkg_name=$(get_pkgname_from_portdir "${pkg_portdir}") &&
					install_package "${pkg_portdir}" ;;
			*)	install_pkg_binary "${pkg_binary}" ;;
			esac
		}; then
			remove_preserved_files ${pkg_name}
			result=done
			set_automatic_flag ${pkg_name} ${automatic_flag} || return 1
		else
			err="install error"
			restore_package "${old_pkg}" || {
				warn "Failed to restore the old version," \
				"please reinstall '${old_pkg}' manually."
				return 1
			}
			remove_preserved_files ${cur_pkgname}
			set_automatic_flag ${cur_pkgname} ${automatic_flag} || return 1
		fi
	else
		err="deinstall error"
	fi

	process_package "${old_pkg}" ||
		warn "Failed to keep the old version."
	clean_libs ||
		warn "Failed to remove the preserved shared libraries."
	remove_dir "${pkg_tmpdir}" ||
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

	printf "\\r%-$(tput co)s\\r" "--->  Checking version: $1" >&2

	if set_pkginfo_replace $1 ''; then
		case ${pkg_name} in
		"$1")	return 0 ;;
		esac
		has_config 'IGNORE' && err=ignored
	elif isempty "${pkg_name}"; then
		return 0
	fi

	printf "\\r%-$(tput co)s\\r" " " >&2

	case ${err} in
	ignored|removed|skipped|subpackage)
		warn "${err:+[${err}] }$1${pkg_name:+ -> ${pkg_name}}${pkg_origin:+ (${pkg_origin})}"
		return 0 ;;
	*)
		echo "${err:+[${err}] }$1${pkg_name:+ -> ${pkg_name}}${pkg_origin:+ (${pkg_origin})}" ;;
	esac
}

remove_compat_libs() {
	local pkgs=$@ file=
	isempty ${pkgs} && return 0
	istrue ${opt_batch} && {
		info "Remove the same name libraries in '${PKGCOMPATDIR}'" &&
		prompt_yesno || return 0
	}
	for file in $(${PKG_QUERY} '%Fp' ${pkgs}); do
		file=${file##*/}
		case ${file} in
		*.so.[0-9]*|*.so)
			istrue ${opt_verbose} && info "Checking '${PKGCOMPATDIR}/${file}'"
			[ -e ${PKGCOMPATDIR}/${file} ] && {
				info "Remove the same name library: '${PKGCOMPATDIR}/${file}'"
				! istrue ${opt_no_execute} &&
					xtry rm -f ${PKGCOMPATDIR}/${file}
			} || istrue ${opt_verbose} &&
				warn "'${PKGCOMPATDIR}/${file}' not found." ;;
		esac
	done
	return 0
}

main() {
	local ARG= ARGV= jobs=0 pids= cnt= X=

	init_pkgtools

	isempty $(which ${PKG_BIN}) &&
		{ warn 'pkg not found. Please install the pkg command.'; exit 1; }

	init_variables
	init_options
	parse_options ${1+"$@"}
	shift $((optind-1))

	load_config "%%ETCDIR%%/pkg_replace.conf"

	isempty ${PKG_REPLACE-} || parse_options ${PKG_REPLACE}

	if istrue ${opt_all} || istrue ${opt_makedb} || { istrue ${opt_version} && ! istrue $#; }; then
		set -- '*'
		[ ${opt_depends} -eq 1 ] && opt_depends=0
		opt_required_by=0
	elif ! isempty ${opt_remove_compat_libs}; then
		remove_compat_libs $(get_installed_pkgname ${opt_remove_compat_libs})
		! istrue $# && exit 0
	elif ! istrue $#; then
		usage
	fi

	[ ${opt_depends} -ge 2 ] && {
		warn "'-dd' or '-RR' option set, this mode is slow!"
		create_dir "${PKG_REPLACE_DB_DIR}"
	}

	parse_args ${1+"$@"}

	istrue ${opt_omit_check} || istrue ${opt_version} || pkg_sort ${upgrade_pkgs}

	istrue ${opt_makedb} && exit 0

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
		set_signal_exit=${set_signal_exit}'show_result; write_result "${opt_result}"; clean_tmpdir; '
		set_signal_handlers

		# check installed package
		for X in ${upgrade_pkgs}; do
			get_installed_pkgname $X > /dev/null 2>&1 || {
				install_pkgs="${install_pkgs} $X";
				upgrade_pkgs=$(echo ${upgrade_pkgs} | sed "s| $X | |g");
			}
		done

		# config
		{ istrue ${opt_config} || istrue ${opt_force_config}; } && {
			set -- ${install_pkgs}
			cnt=0
			ARGV=
			for ARG in ${1+"$@"}; do
				do_install_config "${ARG}" "${ARGV}" || {
					warn "Fix the problem and try again."
					result=failed
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
					result=failed
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
				result=failed
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
				result=failed
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
