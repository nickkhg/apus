if grep -qw mydistro.live /proc/cmdline; then
    echo
    echo "  This is the mydistro live system (read-only)."
    echo "  Run 'mydistro-install' to install it to a disk."
    echo
fi
