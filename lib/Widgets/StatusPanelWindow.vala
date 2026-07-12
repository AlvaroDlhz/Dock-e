// Native reusable panel for the fixed system indicators.

namespace Plank
{
	public class StatusPanelWindow : Gtk.Window
	{
		const int PANEL_WIDTH = 245;
		const int PANEL_HEIGHT = 400;
		const int VOLUME_PANEL_SIZE = 300;
		const int PANEL_GAP = 10;

		unowned DockController controller;
		Gtk.Box content;
		Gtk.Box footer;
		StatusIndicatorItem? current_item;
		Gtk.CssProvider? css_provider;
		int active_panel_width = PANEL_WIDTH;
		int active_panel_height = PANEL_HEIGHT;
		bool device_popup_open = false;

		public StatusPanelWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			decorated = false;
			resizable = false;
			skip_taskbar_hint = true;
			skip_pager_hint = true;
			set_keep_above (true);
			type_hint = Gdk.WindowTypeHint.DIALOG;
			set_default_size (PANEL_WIDTH, PANEL_HEIGHT);
			Gdk.Geometry geometry = {};
			geometry.min_width = PANEL_WIDTH;
			geometry.max_width = PANEL_WIDTH;
			geometry.min_height = PANEL_HEIGHT;
			geometry.max_height = PANEL_HEIGHT;
			set_geometry_hints (null, geometry,
				Gdk.WindowHints.MIN_SIZE | Gdk.WindowHints.MAX_SIZE);
			app_paintable = true;
			var visual = get_screen ().get_rgba_visual ();
			if (visual != null)
				set_visual (visual);
			get_style_context ().add_class ("plank-status-panel");

			var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
			card.margin = 10;
			card.get_style_context ().add_class ("status-card");
			content = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
			var scroll = new Gtk.ScrolledWindow (null, null);
			scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
			scroll.vscrollbar_policy = Gtk.PolicyType.NEVER;
			scroll.overlay_scrolling = true;
			scroll.propagate_natural_width = false;
			scroll.propagate_natural_height = false;
			scroll.get_style_context ().add_class ("status-scroll");
			scroll.add (content);
			card.pack_start (scroll, true, true, 0);
			footer = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
			footer.get_style_context ().add_class ("status-footer");
			card.pack_end (footer, false, false, 0);
			add (card);
			focus_out_event.connect (() => {
				if (!device_popup_open)
					dismiss ();
				return false;
			});
			show.connect (() => {
				controller.hide_manager.ExternalMenuVisible = true;
				controller.hide_manager.update_hovered ();
			});
			hide.connect (() => {
				controller.hide_manager.ExternalMenuVisible = false;
				controller.hide_manager.update_hovered ();
			});
		}

		~StatusPanelWindow ()
		{
			if (css_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), css_provider);
		}

		public void toggle (StatusIndicatorItem item)
		{
			if (visible && current_item == item) {
				dismiss ();
				return;
			}
			current_item = item;
			apply_geometry (item.Kind);
			rebuild (item.Kind);
			apply_theme ();
			opacity = 0.0;
			show_all ();
			present ();
			Idle.add (() => {
				resize (active_panel_width, active_panel_height);
				position_over_item ();
				opacity = 1.0;
				Idle.add (() => { position_over_item (); return false; });
				return false;
			});
		}

		void apply_geometry (StatusIndicatorKind kind)
		{
			if (kind == StatusIndicatorKind.VOLUME) {
				var workarea = active_workarea ();
				var bar = controller.position_manager.get_screen_background_region ();
				var available_above = bar.y - PANEL_GAP - workarea.y;
				var square_size = int.min (VOLUME_PANEL_SIZE,
					int.min (workarea.width - 20, available_above));
				active_panel_width = active_panel_height = int.max (160, square_size);
			} else {
				active_panel_width = PANEL_WIDTH;
				active_panel_height = PANEL_HEIGHT;
			}
			Gdk.Geometry geometry = {};
			geometry.min_width = active_panel_width;
			geometry.max_width = active_panel_width;
			geometry.min_height = active_panel_height;
			geometry.max_height = active_panel_height;
			set_geometry_hints (null, geometry,
				Gdk.WindowHints.MIN_SIZE | Gdk.WindowHints.MAX_SIZE);
			set_size_request (active_panel_width, active_panel_height);
			set_default_size (active_panel_width, active_panel_height);
			resize (active_panel_width, active_panel_height);
		}

		public void dismiss ()
		{
			if (visible)
				hide ();
		}

		void rebuild (StatusIndicatorKind kind)
		{
			foreach (unowned Gtk.Widget child in content.get_children ())
				content.remove (child);
			foreach (unowned Gtk.Widget child in footer.get_children ())
				footer.remove (child);
			content.pack_start (title_row (label_for_kind (kind), icon_for_kind (kind)), false, false, 0);
			content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);
			switch (kind) {
			case StatusIndicatorKind.VOLUME: build_volume (); break;
			case StatusIndicatorKind.BLUETOOTH: build_bluetooth (); break;
			case StatusIndicatorKind.WIFI: build_wifi (); break;
			case StatusIndicatorKind.BATTERY: build_battery (); break;
			case StatusIndicatorKind.CLOCK: build_clock (); break;
			default: break;
			}
		}

		Gtk.Widget title_row (string title, string icon)
		{
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			box.get_style_context ().add_class ("status-title");
			box.pack_start (new Gtk.Image.from_icon_name (icon, Gtk.IconSize.BUTTON), false, false, 0);
			var label = new Gtk.Label (title) { xalign = 0.0f };
			label.get_style_context ().add_class ("status-title-label");
			box.pack_start (label, true, true, 0);
			return box;
		}

		void build_volume ()
		{
			string output;
			var percent = 0.0;
			var muted = false;
			if (run ("wpctl get-volume @DEFAULT_AUDIO_SINK@", out output)) {
				var fields = output.split (" ");
				if (fields.length > 1)
					percent = double.parse (fields[1]) * 100.0;
				muted = output.contains ("[MUTED]");
			}
			content.pack_start (section_label (_("Output")), false, false, 0);
			content.pack_start (device_selector (false), false, false, 0);
			content.pack_start (modern_volume_bar ("@DEFAULT_AUDIO_SINK@", percent, 150,
				"audio-volume-high-symbolic", muted), false, false, 0);

			content.pack_start (section_label (_("Microphone")), false, false, 0);
			content.pack_start (device_selector (true), false, false, 0);
			var mic_percent = get_wpctl_volume ("@DEFAULT_AUDIO_SOURCE@");
			content.pack_start (modern_volume_bar ("@DEFAULT_AUDIO_SOURCE@", mic_percent, 100,
				"audio-input-microphone-symbolic", wpctl_muted ("@DEFAULT_AUDIO_SOURCE@")), false, false, 0);

			var settings = new Gtk.Button.with_label (_("Advanced sound settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("pavucontrol"));
			footer.pack_start (settings, false, false, 0);
		}

		Gtk.Widget modern_volume_bar (string target, double percent, double maximum,
			string icon_name, bool muted)
		{
			var overlay = new Gtk.Overlay ();
			overlay.get_style_context ().add_class ("modern-volume-bar");
			var scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0, maximum, 1);
			scale.draw_value = false;
			scale.has_origin = true;
			scale.height_request = 36;
			scale.set_value (percent);
			scale.get_style_context ().add_class ("modern-volume-scale");
			overlay.add (scale);

			var icon = icon_toggle_button (icon_name, muted);
			icon.halign = Gtk.Align.START;
			icon.valign = Gtk.Align.CENTER;
			icon.margin_start = 5;
			icon.toggled.connect (() => run_action ("wpctl set-mute %s %s".printf (target,
				icon.active ? "1" : "0")));
			overlay.add_overlay (icon);

			var value = new Gtk.Label ("%.0f%%".printf (percent));
			value.halign = Gtk.Align.END;
			value.valign = Gtk.Align.CENTER;
			value.margin_end = 10;
			value.get_style_context ().add_class ("modern-volume-value");
			overlay.add_overlay (value);
			overlay.set_overlay_pass_through (value, true);
			scale.value_changed.connect (() => {
				run_action ("wpctl set-volume %s %.0f%%".printf (target, scale.get_value ()));
				value.label = "%.0f%%".printf (scale.get_value ());
			});
			return overlay;
		}

		Gtk.ToggleButton icon_toggle_button (string icon, bool active)
		{
			var button = new Gtk.ToggleButton ();
			button.active = active;
			button.get_style_context ().add_class ("status-icon-toggle");
			button.add (new Gtk.Image.from_icon_name (icon, Gtk.IconSize.MENU));
			return button;
		}

		Gtk.Widget section_label (string text)
		{
			var label = new Gtk.Label (text) { xalign = 0.0f };
			label.get_style_context ().add_class ("status-section-label");
			return label;
		}

		Gtk.Widget device_selector (bool source)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			row.get_style_context ().add_class ("status-row");
			var combo = new Gtk.ComboBoxText ();
			combo.get_style_context ().add_class ("modern-device-selector");
			foreach (unowned Gtk.CellRenderer renderer in combo.get_cells ()) {
				var text_renderer = renderer as Gtk.CellRendererText;
				if (text_renderer != null) {
					text_renderer.ellipsize = Pango.EllipsizeMode.END;
					text_renderer.width_chars = 14;
				}
			}
			string current = "";
			string output = "";
			run (source ? "pactl get-default-source" : "pactl get-default-sink", out current);
			if (run (source ? "pactl list short sources" : "pactl list short sinks", out output)) {
				foreach (unowned string line in output.split ("\n")) {
					var fields = line.split ("\t");
					if (fields.length < 2 || (source && fields[1].has_suffix (".monitor")))
						continue;
					combo.append (fields[1], friendly_device_name (fields[1]));
				}
			}
			combo.active_id = current.strip ();
			combo.notify["popup-shown"].connect (() => {
				device_popup_open = combo.popup_shown;
				if (!device_popup_open && visible)
					Idle.add (() => { present (); return false; });
			});
			combo.changed.connect (() => {
				if (combo.active_id != null) {
					run_action ((source ? "pactl set-default-source " : "pactl set-default-sink ") + Shell.quote (combo.active_id));
					move_active_streams (source, combo.active_id);
				}
			});
			row.pack_start (combo, true, true, 0);
			return row;
		}

		void move_active_streams (bool source, string device)
		{
			string output;
			var list_command = source ? "pactl list short source-outputs" : "pactl list short sink-inputs";
			if (!run (list_command, out output))
				return;
			foreach (unowned string line in output.split ("\n")) {
				var fields = line.split ("\t");
				if (fields.length < 1 || fields[0] == "")
					continue;
				run_action ((source ? "pactl move-source-output " : "pactl move-sink-input ")
					+ fields[0] + " " + Shell.quote (device));
			}
		}

		string friendly_device_name (string name)
		{
			var result = name.replace ("alsa_output.", "").replace ("alsa_input.", "");
			result = result.replace ("bluez_output.", "Bluetooth · ").replace ("bluez_input.", "Bluetooth · ");
			result = result.replace ("_", " ").replace (".", " · ");
			return result;
		}

		double get_wpctl_volume (string target)
		{
			string output;
			if (!run ("wpctl get-volume " + target, out output))
				return 0.0;
			var fields = output.split (" ");
			return fields.length > 1 ? double.parse (fields[1]) * 100.0 : 0.0;
		}

		bool wpctl_muted (string target)
		{
			string output;
			return run ("wpctl get-volume " + target, out output) && output.contains ("[MUTED]");
		}

		void build_bluetooth ()
		{
			var powered = contains ("bluetoothctl show", "Powered: yes");
			content.pack_start (switch_row (_("Bluetooth"), powered, (state) => {
				run_action ("bluetoothctl power " + (state ? "on" : "off"));
			}), false, false, 0);
			string output = "";
			if (powered && run ("bluetoothctl devices Paired", out output))
				foreach (unowned string line in output.split ("\n")) {
					var fields = line.split (" ", 3);
					if (fields.length >= 3)
						content.pack_start (info_row (fields[2], _("Paired")), false, false, 0);
				}
		}

		void build_wifi ()
		{
			string output = "";
			var enabled = run ("nmcli radio wifi", out output) && output.strip () == "enabled";
			content.pack_start (switch_row (_("Wi-Fi"), enabled, (state) => {
				run_action ("nmcli radio wifi " + (state ? "on" : "off"));
			}), false, false, 0);
			if (enabled && run ("nmcli -t -f IN-USE,SSID,SIGNAL device wifi list --rescan no", out output)) {
				var shown = 0;
				foreach (unowned string line in output.split ("\n")) {
					var fields = line.split (":");
					if (fields.length < 3 || fields[1] == "" || shown++ >= 5)
						continue;
					content.pack_start (info_row (fields[1], _("Signal %s%%").printf (fields[2])), false, false, 0);
				}
			}
		}

		void build_battery ()
		{
			string capacity = "0";
			string state = _("Not available");
			try {
				var directory = Dir.open ("/sys/class/power_supply");
				string? name;
				while ((name = directory.read_name ()) != null)
					if (name.has_prefix ("BAT")) {
						FileUtils.get_contents ("/sys/class/power_supply/%s/capacity".printf (name), out capacity);
						FileUtils.get_contents ("/sys/class/power_supply/%s/status".printf (name), out state);
						break;
					}
			} catch (FileError e) {}
			content.pack_start (info_row (_("%s%% remaining").printf (capacity.strip ()), state.strip ()), false, false, 0);
		}

		void build_clock ()
		{
			var now = new DateTime.now_local ();
			content.pack_start (info_row (now.format ("%H:%M"), now.format ("%A, %e %B")), false, false, 0);
			var calendar = new Gtk.Calendar ();
			calendar.show_heading = true;
			calendar.show_day_names = true;
			content.pack_start (calendar, false, false, 0);
		}

		delegate void SwitchChanged (bool state);
		Gtk.Widget switch_row (string label, bool state, owned SwitchChanged changed)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			row.get_style_context ().add_class ("status-row");
			row.pack_start (new Gtk.Label (label) { xalign = 0.0f }, true, true, 0);
			var toggle = new Gtk.Switch () { active = state, valign = Gtk.Align.CENTER };
			toggle.notify["active"].connect (() => changed (toggle.active));
			row.pack_end (toggle, false, false, 0);
			return row;
		}

		Gtk.Widget info_row (string title, string subtitle)
		{
			var row = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			row.get_style_context ().add_class ("status-row");
			row.pack_start (new Gtk.Label (title) { xalign = 0.0f }, false, false, 0);
			var sub = new Gtk.Label (subtitle) { xalign = 0.0f };
			sub.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			row.pack_start (sub, false, false, 0);
			return row;
		}

		void position_over_item ()
		{
			if (current_item == null)
				return;
			var item = controller.position_manager.get_screen_region_for_item (current_item);
			var bar = controller.position_manager.get_screen_background_region ();
			var workarea = active_workarea ();
			int actual_width, actual_height;
			get_size (out actual_width, out actual_height);
			var desired_x = item.x + item.width / 2 - actual_width / 2;
			var min_x = workarea.x + 8;
			var max_x = workarea.x + workarea.width - actual_width - 8;
			var desired_y = bar.y - actual_height - PANEL_GAP;
			var min_y = workarea.y + 8;
			var max_y = workarea.y + workarea.height - actual_height - 8;
			move (int.max (min_x, int.min (max_x, desired_x)),
				int.max (min_y, int.min (max_y, desired_y)));
		}

		Gdk.Rectangle active_workarea ()
		{
			var screen = get_screen ();
			var bar = controller.position_manager.get_screen_background_region ();
			var monitor = screen.get_monitor_at_point (bar.x + bar.width / 2, bar.y + bar.height / 2);
			return screen.get_monitor_workarea (monitor);
		}

		void apply_theme ()
		{
			var color = controller.renderer.theme.FillStartColor;
			var css = ".plank-status-panel { background: transparent; }";
			css += ".plank-status-panel .status-card { background-color: rgba(%d,%d,%d,%.3f); border: 1px solid rgba(255,255,255,0.10); border-radius: 12px; padding: 7px; }"
				.printf ((int)(color.red*255), (int)(color.green*255), (int)(color.blue*255), color.alpha);
			css += ".plank-status-panel .status-title { padding: 5px 7px; color: white; }";
			css += ".plank-status-panel .status-title-label { font-weight: bold; font-size: 15px; }";
			css += ".plank-status-panel .status-row { color: white; padding: 4px 6px; border-radius: 8px; }";
			css += ".plank-status-panel .status-section-label { color: rgba(255,255,255,0.58); font-size: 10px; font-weight: bold; margin: 4px 6px 0 6px; }";
			css += ".plank-status-panel .status-action-button { color: white; background-color: rgba(255,255,255,0.08); background-image: none; border: none; border-radius: 8px; box-shadow: none; padding: 5px; margin-top: 4px; }";
			css += ".plank-status-panel .status-footer { padding-top: 4px; }";
			css += ".plank-status-panel .status-icon-toggle { color: rgba(255,255,255,0.65); background: transparent; background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px; }";
			css += ".plank-status-panel .status-icon-toggle:checked { color: white; background-color: rgba(255,255,255,0.14); }";
			css += ".plank-status-panel .modern-volume-bar { margin: 2px 6px 5px 6px; }";
			css += ".plank-status-panel .modern-volume-scale trough { min-height: 36px; background-color: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.08); border-radius: 10px; }";
			css += ".plank-status-panel .modern-volume-scale highlight { background-color: rgba(115,210,22,0.48); border-radius: 9px; }";
			css += ".plank-status-panel .modern-volume-scale slider { min-width: 0; min-height: 0; margin: 0; padding: 0; background: transparent; border: none; box-shadow: none; }";
			css += ".plank-status-panel .modern-volume-bar .status-icon-toggle { color: white; background: transparent; padding: 5px; }";
			css += ".plank-status-panel .modern-volume-value { color: white; font-size: 11px; font-weight: bold; }";
			css += ".plank-status-panel .modern-device-selector { color: white; background: transparent; border: none; box-shadow: none; padding: 0; }";
			css += ".plank-status-panel .modern-device-selector button { color: white; background-color: rgba(255,255,255,0.07); background-image: none; border: 1px solid rgba(255,255,255,0.09); border-radius: 9px; box-shadow: none; padding: 6px 9px; }";
			css += ".plank-status-panel .modern-device-selector button:hover { background-color: rgba(255,255,255,0.11); }";
			css += ".plank-status-panel separator { background-color: rgba(255,255,255,0.10); }";
			css += ".plank-status-panel .status-scroll { background: transparent; border: none; box-shadow: none; }";
			css += ".plank-status-panel scrollbar { background: transparent; border: none; }";
			css += ".plank-status-panel scrollbar slider { min-width: 4px; min-height: 28px; background-color: rgba(255,255,255,0.18); border-radius: 4px; }";
			if (css_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), css_provider);
			css_provider = new Gtk.CssProvider ();
			try { css_provider.load_from_data (css); } catch (Error e) { warning ("Status panel CSS: %s", e.message); }
			Gtk.StyleContext.add_provider_for_screen (get_screen (), css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
		}

		static bool run (string command, out string output)
		{
			string error; int status;
			try {
				Process.spawn_command_line_sync (command, out output, out error, out status);
				return status == 0;
			} catch (SpawnError e) { output = ""; return false; }
		}
		static void run_action (string command) { string output; run (command, out output); }
		static void launch (string command) { try { Process.spawn_command_line_async (command); } catch (SpawnError e) {} }
		static bool contains (string command, string needle) { string output; return run (command, out output) && output.contains (needle); }
		static string label_for_kind (StatusIndicatorKind kind) {
			switch (kind) {
			case StatusIndicatorKind.VOLUME: return _("Volume"); case StatusIndicatorKind.BLUETOOTH: return _("Bluetooth");
			case StatusIndicatorKind.WIFI: return _("Wi-Fi"); case StatusIndicatorKind.BATTERY: return _("Battery");
			case StatusIndicatorKind.CLOCK: return _("Time and date"); default: return "";
			}
		}
		static string icon_for_kind (StatusIndicatorKind kind) {
			switch (kind) {
			case StatusIndicatorKind.VOLUME: return "audio-volume-high-symbolic"; case StatusIndicatorKind.BLUETOOTH: return "bluetooth-symbolic";
			case StatusIndicatorKind.WIFI: return "network-wireless-symbolic"; case StatusIndicatorKind.BATTERY: return "battery-good-symbolic";
			case StatusIndicatorKind.CLOCK: return "preferences-system-time-symbolic"; default: return "preferences-system-symbolic";
			}
		}
	}
}
