# Runs once at power-on, before code.py.
#
# CircuitPython exposes one USB serial port by default: the REPL console. The
# protocol needs its own channel, so enable the second ("data") port and leave
# the console alone for debugging.
#
# Changes here only take effect after a hard reset — power-cycle the Keybow or
# press its reset button. Ctrl-D in the REPL is not enough.

import usb_cdc

usb_cdc.enable(console=True, data=True)
