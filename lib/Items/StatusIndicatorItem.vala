//
// Native, fixed system indicators for Plank.
//

namespace Plank
{
	public enum StatusIndicatorKind
	{
		CLOCK,
		DATE,
		WIFI,
		VOLUME,
		BLUETOOTH,
		BATTERY
	}

	public class StatusIndicatorItem : DockItem
	{
		public StatusIndicatorKind Kind { get; construct; }

		bool active = true;
		bool muted = false;
		double volume_level = 0.0;
		int battery_percent = 0;
		bool battery_charging = false;
		uint update_timer_id = 0U;

		public StatusIndicatorItem (StatusIndicatorKind kind)
		{
			Object (Kind: kind, Prefs: new DockItemPreferences (), Text: get_label (kind));
		}

		construct
		{
			Button = PopupButton.LEFT | PopupButton.RIGHT;
			update_state ();
			update_timer_id = Timeout.add_seconds (1, () => {
				update_state ();
				return true;
			});
		}

		~StatusIndicatorItem ()
		{
			if (update_timer_id > 0U)
				Source.remove (update_timer_id);
		}

		static string get_label (StatusIndicatorKind kind)
		{
			switch (kind) {
			case StatusIndicatorKind.CLOCK: return _("Time");
			case StatusIndicatorKind.DATE: return _("Date");
			case StatusIndicatorKind.WIFI: return _("Network");
			case StatusIndicatorKind.VOLUME: return _("Volume");
			case StatusIndicatorKind.BLUETOOTH: return _("Bluetooth");
			case StatusIndicatorKind.BATTERY: return _("Battery");
			default: return "";
			}
		}

		void update_state ()
		{
			var old_active = active;
			var old_muted = muted;
			var old_volume_level = volume_level;
			var old_battery_percent = battery_percent;
			var old_battery_charging = battery_charging;

			switch (Kind) {
			case StatusIndicatorKind.WIFI:
				active = NetworkMonitor.get_default ().network_available;
				break;
			case StatusIndicatorKind.VOLUME:
				update_volume_state ();
				break;
			case StatusIndicatorKind.BLUETOOTH:
				active = command_output_contains ("bluetoothctl show", "Powered: yes");
				break;
			case StatusIndicatorKind.BATTERY:
				update_battery_state ();
				break;
			default:
				break;
			}

			// Time-based indicators need a fresh buffer even if their state did not change.
			if (Kind == StatusIndicatorKind.CLOCK || Kind == StatusIndicatorKind.DATE
				|| old_active != active || old_muted != muted
				|| Math.fabs (old_volume_level - volume_level) > 0.005
				|| old_battery_percent != battery_percent
				|| old_battery_charging != battery_charging)
				reset_icon_buffer ();
		}

		void update_battery_state ()
		{
			active = false;
			try {
				var directory = Dir.open ("/sys/class/power_supply");
				string? name;
				while ((name = directory.read_name ()) != null) {
					if (!name.has_prefix ("BAT"))
						continue;
					string capacity;
					string status;
					if (!FileUtils.get_contents ("/sys/class/power_supply/%s/capacity".printf (name), out capacity))
						continue;
					FileUtils.get_contents ("/sys/class/power_supply/%s/status".printf (name), out status);
					battery_percent = int.parse (capacity.strip ());
					battery_charging = status.strip () == "Charging" || status.strip () == "Full";
					active = true;
					break;
				}
			} catch (FileError e) {
				active = false;
			}
		}

		void update_volume_state ()
		{
			string output = "";
			active = run_command ("wpctl get-volume @DEFAULT_AUDIO_SINK@", out output);
			muted = active && output.contains ("[MUTED]");
			volume_level = 0.0;
			if (active) {
				var fields = output.split (" ");
				if (fields.length > 1)
					volume_level = double.parse (fields[1]);
			}
		}

		static bool command_output_contains (string command, string needle)
		{
			string output = "";
			return run_command (command, out output) && output.contains (needle);
		}

		static bool run_command (string command, out string output)
		{
			string standard_output;
			string standard_error;
			int status;
			try {
				Process.spawn_command_line_sync (command, out standard_output, out standard_error, out status);
				output = standard_output;
				return status == 0;
			} catch (SpawnError e) {
				output = "";
				return false;
			}
		}

		static bool run_action (string command)
		{
			string output;
			return run_command (command, out output);
		}

		static void launch_command (string command)
		{
			try {
				AppInfo.create_from_commandline (command, null, AppInfoCreateFlags.NONE).launch (null, null);
			} catch (Error e) {
				warning ("Unable to launch '%s': %s", command, e.message);
			}
		}

		public override bool can_be_removed ()
		{
			return false;
		}

		protected override AnimationType on_hovered ()
		{
			return AnimationType.LIGHTEN;
		}

		protected override AnimationType on_clicked (PopupButton button, Gdk.ModifierType mod, uint32 event_time)
		{
			if (button == PopupButton.LEFT) {
				unowned DockController? dock = get_dock ();
				if (dock != null)
					dock.status_panel.toggle (this);
				return AnimationType.DARKEN;
			}
			if (Kind == StatusIndicatorKind.VOLUME && button == PopupButton.MIDDLE) {
				run_action ("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle");
				update_state ();
			}

			return AnimationType.NONE;
		}

		protected override AnimationType on_scrolled (Gdk.ScrollDirection direction,
			Gdk.ModifierType mod, uint32 event_time)
		{
			if (Kind == StatusIndicatorKind.VOLUME) {
				if (direction == Gdk.ScrollDirection.UP)
					run_action ("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+");
				else if (direction == Gdk.ScrollDirection.DOWN)
					run_action ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-");
				update_state ();
			}

			return AnimationType.NONE;
		}

		public override Gee.ArrayList<Gtk.MenuItem> get_menu_items ()
		{
			switch (Kind) {
			case StatusIndicatorKind.VOLUME: return get_volume_menu_items ();
			case StatusIndicatorKind.BLUETOOTH: return get_bluetooth_menu_items ();
			case StatusIndicatorKind.WIFI: return get_wifi_menu_items ();
			case StatusIndicatorKind.CLOCK: return get_clock_menu_items ();
			case StatusIndicatorKind.BATTERY: return get_battery_menu_items ();
			default: return new Gee.ArrayList<Gtk.MenuItem> ();
			}
		}

		Gee.ArrayList<Gtk.MenuItem> get_battery_menu_items ()
		{
			var items = new Gee.ArrayList<Gtk.MenuItem> ();
			var state = !active ? _("Not available") :
				(battery_charging ? _("Charging") : _("On battery"));
			items.add (create_status_item (_("Battery · %d%%").printf (battery_percent), state,
				battery_charging ? "battery-good-charging-symbolic" : "battery-good-symbolic", active));
			items.add (new Gtk.SeparatorMenuItem ());
			var settings = create_menu_item (_("Power _Settings"), "preferences-system-power-symbolic");
			settings.activate.connect (() => launch_command ("xfce4-power-manager-settings"));
			items.add (settings);
			return items;
		}

		Gee.ArrayList<Gtk.MenuItem> get_volume_menu_items ()
		{
			var items = new Gee.ArrayList<Gtk.MenuItem> ();
			items.add (new TitledSeparatorMenuItem.no_line (_("Sound")));

			var scale_item = new Gtk.MenuItem ();
			var scale_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			scale_box.margin = 8;
			var volume_icon = new Gtk.Image.from_icon_name (muted ? "audio-volume-muted-symbolic" :
				"audio-volume-high-symbolic", Gtk.IconSize.MENU);
			var scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0.0, 100.0, 1.0);
			scale.width_request = 190;
			scale.draw_value = false;
			scale.set_value (get_volume_percent ());
			var percent = new Gtk.Label ("%.0f%%".printf (scale.get_value ())) { width_request = 42, xalign = 1.0f };
			scale.value_changed.connect (() => {
				run_action ("wpctl set-volume @DEFAULT_AUDIO_SINK@ %.0f%%".printf (scale.get_value ()));
				percent.label = "%.0f%%".printf (scale.get_value ());
				update_state ();
			});
			scale_box.pack_start (volume_icon, false, false, 0);
			scale_box.pack_start (scale, true, true, 0);
			scale_box.pack_start (percent, false, false, 0);
			scale_item.add (scale_box);
			items.add (scale_item);

			var mute_item = new Gtk.CheckMenuItem.with_mnemonic (_("_Mute"));
			mute_item.active = muted;
			mute_item.activate.connect (() => {
				run_action ("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle");
				update_state ();
			});
			items.add (mute_item);
			items.add (settings_item (_("Sound _Settings"), "sound"));
			return items;
		}

		Gee.ArrayList<Gtk.MenuItem> get_wifi_menu_items ()
		{
			var items = new Gee.ArrayList<Gtk.MenuItem> ();
			string output = "";
			var enabled = run_command ("nmcli radio wifi", out output) && output.strip () == "enabled";
			Gtk.Switch toggle;
			items.add (create_switch_item (_("Wi-Fi"), "network-wireless-symbolic", enabled, out toggle));
			toggle.notify["active"].connect (() => {
				run_action ("nmcli radio wifi " + (toggle.active ? "on" : "off"));
				update_state ();
			});

			if (enabled && run_command ("nmcli -t -f IN-USE,SSID,SIGNAL device wifi list --rescan no", out output)) {
				items.add (new Gtk.SeparatorMenuItem ());
				items.add (new TitledSeparatorMenuItem.no_line (_("Available Networks")));
				var seen = new Gee.HashSet<string> ();
				foreach (unowned string line in output.split ("\n")) {
					var fields = line.split (":");
					if (fields.length < 3 || fields[1] == "" || fields[1] in seen)
						continue;
					seen.add (fields[1]);
					var network_item = create_status_item (fields[1], _("Signal %s%%").printf (fields[2]),
						wifi_icon_for_signal (fields[2]), fields[0] == "*");
					var ssid = fields[1];
				network_item.activate.connect (() => run_action ("nmcli connection up id " + Shell.quote (ssid)));
					items.add (network_item);
				}
			}

			items.add (new Gtk.SeparatorMenuItem ());
			items.add (settings_item (_("Network _Settings"), "network"));
			return items;
		}

		Gee.ArrayList<Gtk.MenuItem> get_bluetooth_menu_items ()
		{
			var items = new Gee.ArrayList<Gtk.MenuItem> ();
			string output = "";
			var powered = command_output_contains ("bluetoothctl show", "Powered: yes");
			Gtk.Switch toggle;
			items.add (create_switch_item (_("Bluetooth"), "bluetooth-symbolic", powered, out toggle));
			toggle.notify["active"].connect (() => {
				run_action ("bluetoothctl power " + (toggle.active ? "on" : "off"));
				update_state ();
			});

			if (powered && run_command ("bluetoothctl devices Paired", out output)) {
				items.add (new Gtk.SeparatorMenuItem ());
				items.add (new TitledSeparatorMenuItem.no_line (_("Devices")));
				foreach (unowned string line in output.split ("\n")) {
					var fields = line.split (" ", 3);
					if (fields.length < 3)
						continue;
					var address = fields[1];
					var connected = command_output_contains ("bluetoothctl info " + Shell.quote (address), "Connected: yes");
					var device_item = create_status_item (fields[2], connected ? _("Connected") : _("Available"),
						"bluetooth-symbolic", connected);
					device_item.activate.connect (() => {
						run_action ("bluetoothctl " + (connected ? "disconnect " : "connect ") + Shell.quote (address));
						update_state ();
					});
					items.add (device_item);
				}
			}

			items.add (new Gtk.SeparatorMenuItem ());
			items.add (settings_item (_("Bluetooth _Settings"), "bluetooth"));
			return items;
		}

		Gee.ArrayList<Gtk.MenuItem> get_clock_menu_items ()
		{
			var items = new Gee.ArrayList<Gtk.MenuItem> ();
			var now = new DateTime.now_local ();
			items.add (new TitledSeparatorMenuItem.no_line (now.format ("%H:%M  ·  %A, %e %B")));
			var calendar_item = new Gtk.MenuItem ();
			var month = new Gtk.Calendar ();
			month.margin = 6;
			month.show_heading = true;
			month.show_day_names = true;
			month.show_week_numbers = false;
			calendar_item.add (month);
			items.add (calendar_item);
			items.add (new Gtk.SeparatorMenuItem ());
			var calendar = create_menu_item (_("Open _Calendar"), "x-office-calendar-symbolic");
			calendar.activate.connect (() => launch_command ("gnome-calendar"));
			items.add (calendar);
			items.add (settings_item (_("Date & Time _Settings"), "datetime"));
			return items;
		}

		Gtk.MenuItem create_switch_item (string title, string icon, bool state, out Gtk.Switch toggle)
		{
			var item = new Gtk.MenuItem ();
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			box.margin = 8;
			box.pack_start (new Gtk.Image.from_icon_name (icon, Gtk.IconSize.MENU), false, false, 0);
			box.pack_start (new Gtk.Label (title) { xalign = 0.0f }, true, true, 0);
			toggle = new Gtk.Switch ();
			toggle.active = state;
			toggle.valign = Gtk.Align.CENTER;
			box.pack_end (toggle, false, false, 0);
			item.add (box);
			return item;
		}

		Gtk.MenuItem create_status_item (string title, string subtitle, string icon, bool selected)
		{
			var item = new Gtk.MenuItem ();
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			box.margin = 7;
			box.pack_start (new Gtk.Image.from_icon_name (icon, Gtk.IconSize.MENU), false, false, 0);
			var text = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			var title_label = new Gtk.Label (null) { xalign = 0.0f };
			title_label.set_markup (selected ? "<b>%s</b>".printf (Markup.escape_text (title)) : Markup.escape_text (title));
			var subtitle_label = new Gtk.Label (subtitle) { xalign = 0.0f };
			subtitle_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			text.pack_start (title_label, false, false, 0);
			text.pack_start (subtitle_label, false, false, 0);
			box.pack_start (text, true, true, 0);
			if (selected)
				box.pack_end (new Gtk.Image.from_icon_name ("object-select-symbolic", Gtk.IconSize.MENU), false, false, 0);
			item.add (box);
			return item;
		}

		string wifi_icon_for_signal (string signal_text)
		{
			var signal = int.parse (signal_text);
			if (signal >= 75) return "network-wireless-signal-excellent-symbolic";
			if (signal >= 50) return "network-wireless-signal-good-symbolic";
			if (signal >= 25) return "network-wireless-signal-ok-symbolic";
			return "network-wireless-signal-weak-symbolic";
		}

		Gtk.MenuItem settings_item (string label, string panel)
		{
			var item = create_menu_item (label, "preferences-system-symbolic");
			item.activate.connect (() => launch_command ("gnome-control-center " + panel));
			return item;
		}

		double get_volume_percent ()
		{
			string output;
			if (!run_command ("wpctl get-volume @DEFAULT_AUDIO_SINK@", out output))
				return 0.0;
			var fields = output.split (" ");
			if (fields.length < 2)
				return 0.0;
			return double.parse (fields[1]) * 100.0;
		}

		protected override void draw_icon (Surface surface)
		{
			unowned Cairo.Context cr = surface.Context;
			var size = double.min (surface.Width, surface.Height);
			var alpha = active && !muted ? 0.92 : 0.38;
			cr.set_source_rgba (1.0, 1.0, 1.0, alpha);
			cr.set_line_width (double.max (1.5, size * 0.045));
			cr.set_line_cap (Cairo.LineCap.ROUND);
			cr.set_line_join (Cairo.LineJoin.ROUND);

			switch (Kind) {
			case StatusIndicatorKind.CLOCK:
				var now = new DateTime.now_local ();
				draw_text_right_at (cr, surface, now.format ("%H:%M"), size * 0.245, size * 0.34);
				draw_text_right_at (cr, surface, now.format ("%d/%m/%y"), size * 0.245, size * 0.70);
				break;
			case StatusIndicatorKind.DATE:
				draw_text (cr, surface, new DateTime.now_local ().format ("%d/%m"), size * 0.24);
				break;
			case StatusIndicatorKind.WIFI:
				draw_lucide (surface, "wifi", alpha);
				break;
			case StatusIndicatorKind.VOLUME:
				var volume_icon = muted || !active ? "volume-x" :
					(volume_level <= 0.01 ? "volume" : (volume_level < 0.50 ? "volume-1" : "volume-2"));
				draw_lucide (surface, volume_icon, alpha);
				if (volume_level > 1.0 && !muted) {
					cr.set_source_rgba (1.0, 1.0, 1.0, alpha);
					cr.arc (size * 0.84, size * 0.22, size * 0.035, 0, Math.PI * 2.0);
					cr.fill ();
				}
				break;
			case StatusIndicatorKind.BLUETOOTH:
				draw_lucide (surface, "bluetooth", alpha);
				break;
			case StatusIndicatorKind.BATTERY:
				var battery_icon = battery_charging ? "battery-charging" :
					(battery_percent < 34 ? "battery-low" : (battery_percent < 67 ? "battery-medium" : "battery-full"));
				draw_lucide (surface, battery_icon, alpha);
				break;
			}
		}

		void draw_lucide (Surface surface, string name, double alpha)
		{
			var icon_size = (int) (double.min (surface.Width, surface.Height) * 0.54);
			try {
				var pixbuf = new Gdk.Pixbuf.from_resource_at_scale (
					"%s/lucide/%s.svg".printf (Plank.G_RESOURCE_PATH, name), icon_size, icon_size, true);
				unowned Cairo.Context cr = surface.Context;
				var x = (surface.Width - pixbuf.width) / 2.0;
				var y = (surface.Height - pixbuf.height) / 2.0;
				Gdk.cairo_set_source_pixbuf (cr, pixbuf, x, y);
				cr.paint_with_alpha (alpha);
			} catch (Error e) {
				warning ("Unable to load Lucide icon '%s': %s", name, e.message);
			}
		}

		void draw_text (Cairo.Context cr, Surface surface, string text, double font_size)
		{
			Cairo.TextExtents extents;
			cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
			cr.set_font_size (font_size);
			cr.text_extents (text, out extents);
			cr.move_to ((surface.Width - extents.width) / 2.0 - extents.x_bearing,
				(surface.Height - extents.height) / 2.0 - extents.y_bearing);
			cr.show_text (text);
		}

		void draw_text_right_at (Cairo.Context cr, Surface surface, string text,
			double font_size, double center_y)
		{
			Cairo.TextExtents extents;
			cr.select_font_face ("Sans Condensed", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
			cr.set_font_size (font_size);
			cr.text_extents (text, out extents);
			var padding = size_for_text_padding (surface);
			var available_width = surface.Width - 2.0 * padding;
			var horizontal_scale = double.min (1.0, available_width / extents.width);
			cr.save ();
			cr.translate (surface.Width - padding, 0.0);
			cr.scale (horizontal_scale, 1.0);
			cr.move_to (-extents.width - extents.x_bearing,
				center_y - extents.height / 2.0 - extents.y_bearing);
			cr.show_text (text);
			cr.restore ();
		}

		double size_for_text_padding (Surface surface)
		{
			return double.min (surface.Width, surface.Height) * 0.04;
		}

		void draw_wifi (Cairo.Context cr, double size)
		{
			var cx = size / 2.0;
			var cy = size * 0.66;
			foreach (var radius in new double[] { size * 0.16, size * 0.29, size * 0.42 }) {
				cr.arc (cx, cy, radius, Math.PI * 1.22, Math.PI * 1.78);
				cr.stroke ();
			}
			cr.arc (cx, cy, size * 0.035, 0, Math.PI * 2.0);
			cr.fill ();
		}

		void draw_volume (Cairo.Context cr, double size, bool is_muted, double level)
		{
			cr.move_to (size * 0.20, size * 0.43);
			cr.line_to (size * 0.34, size * 0.43);
			cr.line_to (size * 0.50, size * 0.29);
			cr.line_to (size * 0.50, size * 0.71);
			cr.line_to (size * 0.34, size * 0.57);
			cr.line_to (size * 0.20, size * 0.57);
			cr.close_path ();
			cr.stroke ();
			if (is_muted) {
				cr.move_to (size * 0.62, size * 0.42);
				cr.line_to (size * 0.78, size * 0.58);
				cr.move_to (size * 0.78, size * 0.42);
				cr.line_to (size * 0.62, size * 0.58);
				cr.stroke ();
				return;
			}

			var wave_count = level <= 0.01 ? 0 : (level < 0.34 ? 1 : (level < 0.67 ? 2 : 3));
			var radii = new double[] { size * 0.14, size * 0.24, size * 0.34 };
			for (var i = 0; i < wave_count; i++) {
				cr.arc (size * 0.49, size * 0.50, radii[i], -Math.PI / 3.0, Math.PI / 3.0);
				cr.stroke ();
			}
			if (level > 1.0) {
				cr.arc (size * 0.88, size * 0.25, size * 0.035, 0, Math.PI * 2.0);
				cr.fill ();
			}
		}

		void draw_bluetooth (Cairo.Context cr, double size)
		{
			cr.move_to (size * 0.46, size * 0.20);
			cr.line_to (size * 0.70, size * 0.40);
			cr.line_to (size * 0.38, size * 0.66);
			cr.line_to (size * 0.38, size * 0.34);
			cr.line_to (size * 0.70, size * 0.60);
			cr.line_to (size * 0.46, size * 0.80);
			cr.close_path ();
			cr.stroke ();
		}

		void draw_battery (Cairo.Context cr, double size)
		{
			var x = size * 0.20;
			var y = size * 0.34;
			var width = size * 0.55;
			var height = size * 0.32;
			cr.rectangle (x, y, width, height);
			cr.stroke ();
			cr.rectangle (x + width, y + height * 0.30, size * 0.07, height * 0.40);
			cr.fill ();
			var level = double.max (0.0, double.min (1.0, battery_percent / 100.0));
			if (level > 0.0) {
				cr.rectangle (x + size * 0.045, y + size * 0.045,
					(width - size * 0.09) * level, height - size * 0.09);
				cr.fill ();
			}
		}
	}

	public class StatusIndicatorProvider : DockItemProvider
	{
		public StatusIndicatorProvider ()
		{
			Object ();
			add (new StatusIndicatorItem (StatusIndicatorKind.VOLUME));
			add (new StatusIndicatorItem (StatusIndicatorKind.BLUETOOTH));
			add (new StatusIndicatorItem (StatusIndicatorKind.WIFI));
			add (new StatusIndicatorItem (StatusIndicatorKind.BATTERY));
			add (new StatusIndicatorItem (StatusIndicatorKind.CLOCK));
		}

		public override bool can_accept_drop (Gee.ArrayList<string> uris)
		{
			return false;
		}

		public override bool move_to (DockElement move, DockElement target)
		{
			return false;
		}
	}
}
