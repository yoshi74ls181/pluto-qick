# AMD/Xilinx 2022.1 toolchain helpers.
#
# Sourced from ~/.bashrc. Defines functions only and touches nothing at login,
# because sourcing the Xilinx settings scripts eagerly is actively harmful:
#
#   * settings64.sh sets LD_LIBRARY_PATH, and bitbake refuses to run when it is
#     set ("Your environment is misconfigured"). The PYNQ sdbuild flow therefore
#     needs a shell where it ends up unset.
#   * PetaLinux's settings.sh prints a banner and runs environment checks, which
#     is noise on every SSH login.
#   * Each sourcing appends to PATH, so repeated logins bloat it.
#
# Usage:
#   use_vivado      Vivado only (HDL, synthesis, xsim)
#   use_vitis       Vitis, which also brings Vivado and bootgen
#   use_petalinux   Vitis + PetaLinux, LD_LIBRARY_PATH cleared, qemu on PATH.
#                   This is what the antsdr-pynq `make pynq` flow needs.
#   xilinx_env      Report what is currently active.

XILINX_ROOT="${XILINX_ROOT:-/tools/Xilinx}"
XILINX_VER="${XILINX_VER:-2022.1}"

_xe_have() { [ -f "$1" ]; }

_xe_warn_reshell() {
    if [ -n "${_XE_LOADED:-}" ] && [ "${_XE_LOADED}" != "$1" ]; then
        echo "xilinx-env: '${_XE_LOADED}' is already active in this shell." >&2
        echo "            PATH would accumulate; start a fresh shell for '$1'." >&2
        return 1
    fi
    return 0
}

use_vivado() {
    _xe_warn_reshell vivado || return 1
    local s="$XILINX_ROOT/Vivado/$XILINX_VER/settings64.sh"
    _xe_have "$s" || { echo "xilinx-env: not found: $s" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$s"
    export _XE_LOADED=vivado
    echo "xilinx-env: Vivado $XILINX_VER active ($(command -v vivado))"
}

use_vitis() {
    _xe_warn_reshell vitis || return 1
    local s="$XILINX_ROOT/Vitis/$XILINX_VER/settings64.sh"
    _xe_have "$s" || { echo "xilinx-env: not found: $s" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$s"
    export _XE_LOADED=vitis
    echo "xilinx-env: Vitis $XILINX_VER active (vivado: $(command -v vivado))"
}

use_petalinux() {
    _xe_warn_reshell petalinux || return 1
    local v="$XILINX_ROOT/Vitis/$XILINX_VER/settings64.sh"
    local p="$XILINX_ROOT/PetaLinux/$XILINX_VER/settings.sh"
    _xe_have "$v" || { echo "xilinx-env: not found: $v" >&2; return 1; }
    _xe_have "$p" || { echo "xilinx-env: not found: $p" >&2; return 1; }

    # sdbuild resolves qemu with `which qemu-arm-static` at make-parse time and
    # needs 5.2.0 from /opt/qemu, not the distro's 4.2.1 in /usr/bin.
    [ -d /opt/qemu/bin ]         && export PATH="/opt/qemu/bin:$PATH"
    [ -d /opt/crosstool-ng/bin ] && export PATH="/opt/crosstool-ng/bin:$PATH"

    # Order matters: Vitis first, then PetaLinux.
    # shellcheck disable=SC1090
    source "$v"
    # shellcheck disable=SC1090
    source "$p"

    # Non-negotiable for bitbake.
    unset LD_LIBRARY_PATH

    export _XE_LOADED=petalinux
    echo "xilinx-env: Vitis + PetaLinux $XILINX_VER active, LD_LIBRARY_PATH cleared"
    echo "            qemu: $(command -v qemu-arm-static 2>/dev/null || echo 'NOT FOUND')"
}

xilinx_env() {
    echo "loaded        : ${_XE_LOADED:-none}"
    echo "vivado        : $(command -v vivado         2>/dev/null || echo '-')"
    echo "vitis         : $(command -v vitis          2>/dev/null || echo '-')"
    echo "petalinux     : $(command -v petalinux-build 2>/dev/null || echo '-')"
    echo "qemu-arm      : $(command -v qemu-arm-static 2>/dev/null || echo '-')"
    echo "LD_LIBRARY_PATH: ${LD_LIBRARY_PATH-(unset - good for bitbake)}"
}
