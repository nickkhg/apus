# Power

`apus-power` says where the power of the machine comes from: a battery, an adapter, or neither. For a battery it shows how much is left, the watts that go in or out now, and how long that lasts. Press Super, type `power`, and press Enter.

The Power pane of Settings is another thing: it starts the shell or the machine again, or stops it. See [settings.md](settings.md#power).

## The parts

| Part | Where | What it holds |
|---|---|---|
| The views and the parser | `ui/Toolkit/Sources/Power/` | What the files of the kernel mean, and the window and the tile. The Mac tests them (`make test-ui`). |
| The app | `ui/Sources/PowerApp/` | The window, and `Supplies`: what reads `/sys/class/power_supply` and asks `systemd-detect-virt` what the machine is. |
| The bundle | `ui/Apps/Power.app` | `org.apus.power`, colour `A9E34B`. |

The views read the text of the files through the `PowerSource` protocol. The tests give the text of real machines (`ui/Toolkit/Tests/PowerTests/Supplies.swift`): a laptop battery that counts in energy, one that counts in charge, an adapter, a USB port, a mouse, and a machine with none.

## What it reads

The kernel makes a folder in `/sys/class/power_supply` for each battery and each adapter. Power reads the file `uevent` in each one, every two seconds. It holds every value of the supply, one to a line:

```
POWER_SUPPLY_TYPE=Battery
POWER_SUPPLY_STATUS=Discharging
POWER_SUPPLY_POWER_NOW=7400000
POWER_SUPPLY_ENERGY_NOW=41200000
POWER_SUPPLY_ENERGY_FULL=52600000
```

| Power shows | From |
|---|---|
| The charge | `CAPACITY`, or `ENERGY_NOW` over `ENERGY_FULL` |
| The watts | `POWER_NOW`, or `CURRENT_NOW` times `VOLTAGE_NOW` |
| The energy | `ENERGY_NOW` and `ENERGY_FULL`, in µWh, or `CHARGE_NOW` and `CHARGE_FULL`, in µAh, times the voltage |
| The time that is left | `TIME_TO_EMPTY_NOW`, or the energy over the watts |
| The time to full | `TIME_TO_FULL_NOW`, or what is missing over the watts |
| The health | `ENERGY_FULL` over `ENERGY_FULL_DESIGN` |
| The state | `STATUS` of the batteries, and `ONLINE` of the adapters |
| Voltage, cycles, temperature, model | `VOLTAGE_NOW`, `CYCLE_COUNT`, `TEMP` (tenths of a degree), `MANUFACTURER`, `MODEL_NAME`, `TECHNOLOGY` |

The numbers of the kernel are in millionths. Some batteries give a current below zero while they empty, so Power takes the size of the number. A supply with `SCOPE=Device` is the battery of a mouse or a pad and not of the machine: Power lists it under Devices and leaves it out of the charge.

The row of bars is the watts of the last thirty readings, which is a minute.

## A machine with no battery

A VM on a Mac has no battery and no adapter: the Mac has them, and the Virtualization framework gives the guest neither. So `/sys/class/power_supply` is empty in the VM, and that is the case that Apus meets most. Power does not show an error or an empty gauge for it. It says "No battery", says why, and says where it looked.

The reason comes from `systemd-detect-virt`, which Power runs once when it starts:

| It prints | Power says |
|---|---|
| `apple` | This is a virtual machine on a Mac: the charge and the power are in macOS. |
| The name of another VM | This is a virtual machine of that name, and its host has the power. |
| The name of a container | This runs in a container, which sees none of the power. |
| `none`, or nothing | A machine that runs from the wall with no driver for its adapter looks like this, and so does a battery with no driver. |

A machine with an adapter and no battery, as most desktops are, says "On AC power". A battery that comes, such as one of a USB device, shows within two seconds.

## Three sizes

| Size class | What Power draws |
|---|---|
| `large` | The charge, the state and the watts, with the bars; a card for each battery with the values it gives; the adapters; the devices |
| `compact` | The same, with less space around it |
| `widget` | A tile: the charge, the state, a battery, and the watts. With no battery: "No battery", and why in three words. |

## Limits

- A VM on a Mac has no battery, so only the no-battery state can show there. The states with a battery are tested with the text of real machines, on the Mac and in the builder container.
- Power reads; it changes nothing. There is no power profile, no limit of the charge, and no sleep: Apus has no daemon for them.
- A low battery (under 10 %) plays `battery-low` once, and the charger plays `power-plug` and `power-unplug`. There is no notice on the screen yet, because an app cannot send one to the shell. The sounds play only while Power is open. See [sounds.md](sounds.md#who-plays-what).
