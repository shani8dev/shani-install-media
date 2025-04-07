var plasma = getApiVersion(1)

// Create bottom panel (Dock) //

const dock = new Panel

// Basic Dock Geometry
dock.alignment = "center"
dock.height = Math.round(gridUnit * 3.8)
dock.hiding = "dodgewindows"
dock.lengthMode = "fit"
dock.location = "bottom"

// Icons-Only Task Manager
var tasks = dock.addWidget("org.kde.plasma.icontasks")
tasks.currentConfigGroup = ["General"]
tasks.writeConfig("fill", false)
tasks.writeConfig("iconSpacing", 2)
tasks.writeConfig("launchers", "applications:org.kde.discover.desktop,preferred://browser,preferred://filemanager,applications:org.kde.konsole.desktop,applications:org.kde.plasma-systemmonitor.desktop,applications:systemsettings.desktop,file:///var/lib/flatpak/exports/share/applications/org.kde.kate.desktop,file:///var/lib/flatpak/exports/share/applications/org.onlyoffice.desktopeditors.desktop,file:///var/lib/flatpak/exports/share/applications/org.kde.kcalc.desktop")
tasks.writeConfig("maxStripes", 1)
tasks.writeConfig("showOnlyCurrentDesktop", false)
tasks.writeConfig("showOnlyCurrentScreen", false)

// End of Dock creation //
