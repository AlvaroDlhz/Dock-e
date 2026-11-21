NULL =

SUBDIRS = \
	icons \
	themes \
	$(NULL)

if ENABLE_APPORT
SUBDIRS += apport
endif

EXTRA_DIST = \
	application-default-icon.svg \
	areas.svg \
	segundo-plano-closed.svg \
	segundo-plano-open.svg \
	lucide/LICENSE \
	lucide/volume.svg \
	lucide/volume-1.svg \
	lucide/volume-2.svg \
	lucide/volume-x.svg \
	lucide/bluetooth.svg \
	lucide/wifi.svg \
	lucide/battery-low.svg \
	lucide/battery-medium.svg \
	lucide/battery-full.svg \
	lucide/battery-charging.svg \
	lucide/clock.svg \
	plank.appdata.xml.in \
	net.launchpad.plank.gschema.xml.in \
	plank.desktop.in \
	dock-e.desktop.in \
	dock-e-autostart.desktop.in \
	plank.gresource.xml \
	menu-2.svg \
	poof.svg \
	style/dock-e.css \
	ui/preferences.ui \
	$(NULL)

CLEANFILES = \
	plank.appdata.xml \
	plank.desktop \
	dock-e.desktop \
	dock-e-autostart.desktop \
	$(gsettings_SCHEMAS) \
	gschemas.compiled \
	net.launchpad.plank.gschema.valid \
	$(NULL)

applicationsdir = $(datadir)/applications
applications_DATA = dock-e.desktop

# Not started for everybody: it is there to be copied into ~/.config/autostart,
# which scripts/install-dock-e does
autostartdir = $(pkgdatadir)/autostart
autostart_DATA = dock-e-autostart.desktop

# The entries name the program by its full path, since a prefix like ~/.local
# is not always in the PATH of the session
dock-e.desktop dock-e-autostart.desktop: %.desktop: %.desktop.in Makefile
	$(AM_V_GEN) sed -e 's|@bindir[@]|$(bindir)|g' $< > $@ || rm $@

appdatadir = $(datadir)/metainfo
appdata_DATA = plank.appdata.xml

gsettings_SCHEMAS = net.launchpad.plank.gschema.xml

%.gschema.xml: %.gschema.xml.in Makefile
	$(AM_V_GEN) sed -e 's|@GETTEXT_PACKAGE[@]|$(GETTEXT_PACKAGE)|g' \
	$< > $@ || rm $@

@GSETTINGS_RULES@

gschemas.compiled: Makefile $(gsettings_SCHEMAS:.xml=.valid)
	$(AM_V_GEN) $(GLIB_COMPILE_SCHEMAS) --targetdir=$(builddir) $(builddir)

all-local: gschemas.compiled

%.desktop: %.desktop.in
	$(AM_V_GEN)$(MSGFMT) --desktop --keyword= --keyword=Name \
		--keyword=GenericName --keyword=Comment --keyword=Keywords \
		--template $< -d $(top_srcdir)/po -o $@

%.appdata.xml: %.appdata.xml.in
	$(AM_V_GEN)$(MSGFMT) --xml --template $< -d $(top_srcdir)/po -o $@
