if grep -qw apus.live /proc/cmdline; then
    echo
    echo "  This is the Apus live system. Changes are lost at power off."
    echo "  Run 'apus-install' to install it to a disk."
    echo
fi
