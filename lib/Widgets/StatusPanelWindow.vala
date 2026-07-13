// Native reusable panel for the fixed system indicators.

namespace Plank
{
	public class StatusPanelWindow : Gtk.Window
	{
		const int PANEL_WIDTH = 245;
		const int PANEL_HEIGHT = 400;
		const int VOLUME_PANEL_SIZE = 400;
		const int BLUETOOTH_PANEL_SIZE = 400;
		const int WIFI_PANEL_SIZE = 400;
		const int BATTERY_PANEL_SIZE = 400;
		const int CLOCK_PANEL_SIZE = 400;
		const int PANEL_GAP = 10;

		unowned DockController controller;
		Gtk.Box content;
		Gtk.Box footer;
		StatusIndicatorItem? current_item;
		Gtk.CssProvider? css_provider;
		int active_panel_width = PANEL_WIDTH;
		int active_panel_height = PANEL_HEIGHT;
		bool device_popup_open = false;
		uint bluetooth_rebuild_id = 0U;
		bool bluetooth_discovery_owned = false;
		uint wifi_refresh_id = 0U;
		uint clock_display_tick_id = 0U;
		uint countdown_tick_id = 0U;
		uint stopwatch_tick_id = 0U;
		int countdown_seconds = 0;
		int pomodoro_mode = 0;
		int stopwatch_seconds = 0;
		bool stopwatch_running = false;
		Gtk.Label? clock_time_label;
		Gtk.Label? clock_date_label;
		Gtk.Label? clock_zone_label;
		Gtk.Label? countdown_label;
		Gtk.Label? stopwatch_label;
		Gtk.Button? countdown_button;
		unowned AudioService audio_service;
		ulong audio_state_changed_id = 0UL;
		ulong audio_devices_changed_id = 0UL;
		Gtk.Scale? output_volume_scale;
		Gtk.Scale? input_volume_scale;
		Gtk.ToggleButton? output_mute_button;
		Gtk.ToggleButton? input_mute_button;
		Gtk.Label? output_volume_label;
		Gtk.Label? input_volume_label;
		Gtk.ComboBoxText? output_device_combo;
		Gtk.ComboBoxText? input_device_combo;
		bool updating_audio_controls = false;
		unowned BluetoothService bluetooth_service;
		ulong bluetooth_state_changed_id = 0UL;
		ulong bluetooth_devices_changed_id = 0UL;

		public StatusPanelWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			audio_service = AudioService.get_default ();
			audio_state_changed_id = audio_service.state_changed.connect (sync_audio_controls);
			audio_devices_changed_id = audio_service.devices_changed.connect (sync_audio_devices);
			bluetooth_service = BluetoothService.get_default ();
			bluetooth_state_changed_id = bluetooth_service.state_changed.connect (bluetooth_service_changed);
			bluetooth_devices_changed_id = bluetooth_service.devices_changed.connect (bluetooth_service_changed);
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
			if (audio_state_changed_id > 0UL)
				SignalHandler.disconnect (audio_service, audio_state_changed_id);
			if (audio_devices_changed_id > 0UL)
				SignalHandler.disconnect (audio_service, audio_devices_changed_id);
			if (bluetooth_state_changed_id > 0UL)
				SignalHandler.disconnect (bluetooth_service, bluetooth_state_changed_id);
			if (bluetooth_devices_changed_id > 0UL)
				SignalHandler.disconnect (bluetooth_service, bluetooth_devices_changed_id);
			if (bluetooth_rebuild_id > 0U)
				Source.remove (bluetooth_rebuild_id);
			stop_bluetooth_discovery ();
			stop_wifi_refresh ();
			stop_clock_display ();
			if (countdown_tick_id > 0U) Source.remove (countdown_tick_id);
			if (stopwatch_tick_id > 0U) Source.remove (stopwatch_tick_id);
			if (css_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), css_provider);
		}

		public void toggle (StatusIndicatorItem item)
		{
			if (visible && current_item == item) {
				dismiss ();
				return;
			}
			if (current_item != null && current_item.Kind == StatusIndicatorKind.BLUETOOTH
				&& item.Kind != StatusIndicatorKind.BLUETOOTH)
				stop_bluetooth_discovery ();
			if (current_item != null && current_item.Kind == StatusIndicatorKind.WIFI
				&& item.Kind != StatusIndicatorKind.WIFI)
				stop_wifi_refresh ();
			if (current_item != null && current_item.Kind == StatusIndicatorKind.CLOCK
				&& item.Kind != StatusIndicatorKind.CLOCK)
				stop_clock_display ();
			current_item = item;
			apply_geometry (item.Kind);
			if (item.Kind == StatusIndicatorKind.BLUETOOTH)
				start_bluetooth_discovery ();
			if (item.Kind == StatusIndicatorKind.WIFI)
				start_wifi_refresh ();
			rebuild (item.Kind);
			if (item.Kind == StatusIndicatorKind.CLOCK)
				start_clock_display ();
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
			} else if (kind == StatusIndicatorKind.BLUETOOTH) {
				active_panel_width = active_panel_height = BLUETOOTH_PANEL_SIZE;
			} else if (kind == StatusIndicatorKind.WIFI) {
				active_panel_width = active_panel_height = WIFI_PANEL_SIZE;
			} else if (kind == StatusIndicatorKind.BATTERY) {
				active_panel_width = active_panel_height = BATTERY_PANEL_SIZE;
			} else if (kind == StatusIndicatorKind.CLOCK) {
				active_panel_width = active_panel_height = CLOCK_PANEL_SIZE;
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
			if (current_item != null && current_item.Kind == StatusIndicatorKind.BLUETOOTH)
				stop_bluetooth_discovery ();
			if (current_item != null && current_item.Kind == StatusIndicatorKind.WIFI)
				stop_wifi_refresh ();
			if (current_item != null && current_item.Kind == StatusIndicatorKind.CLOCK)
				stop_clock_display ();
			if (visible)
				hide ();
		}

		void rebuild (StatusIndicatorKind kind)
		{
			output_volume_scale = null;
			input_volume_scale = null;
			output_mute_button = null;
			input_mute_button = null;
			output_volume_label = null;
			input_volume_label = null;
			output_device_combo = null;
			input_device_combo = null;
			clock_time_label = null;
			clock_date_label = null;
			clock_zone_label = null;
			countdown_label = null;
			stopwatch_label = null;
			countdown_button = null;
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
			content.pack_start (section_label (_("Output")), false, false, 0);
			content.pack_start (device_selector (AudioTarget.OUTPUT), false, false, 0);
			content.pack_start (modern_volume_bar (AudioTarget.OUTPUT, 150,
				"audio-volume-high-symbolic"), false, false, 0);

			content.pack_start (section_label (_("Microphone")), false, false, 0);
			content.pack_start (device_selector (AudioTarget.INPUT), false, false, 0);
			content.pack_start (modern_volume_bar (AudioTarget.INPUT, 100,
				"audio-input-microphone-symbolic"), false, false, 0);

			var settings = new Gtk.Button.with_label (_("Advanced sound settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("pavucontrol"));
			footer.pack_start (settings, false, false, 0);
			audio_service.refresh.begin ();
			audio_service.refresh_devices.begin ();
		}

		Gtk.Widget modern_volume_bar (AudioTarget target, double maximum, string icon_name)
		{
			var percent = audio_service.get_volume (target) * 100.0;
			var overlay = new Gtk.Overlay ();
			overlay.get_style_context ().add_class ("modern-volume-bar");
			var scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0, maximum, 1);
			scale.draw_value = false;
			scale.has_origin = true;
			scale.height_request = 36;
			scale.set_value (percent);
			scale.get_style_context ().add_class ("modern-volume-scale");
			overlay.add (scale);

			var icon = icon_toggle_button (icon_name, audio_service.is_muted (target));
			icon.halign = Gtk.Align.START;
			icon.valign = Gtk.Align.CENTER;
			icon.margin_start = 5;
			icon.toggled.connect (() => {
				if (!updating_audio_controls)
					audio_service.set_muted.begin (target, icon.active);
			});
			overlay.add_overlay (icon);

			var value = new Gtk.Label ("%.0f%%".printf (percent));
			value.halign = Gtk.Align.END;
			value.valign = Gtk.Align.CENTER;
			value.margin_end = 10;
			value.get_style_context ().add_class ("modern-volume-value");
			overlay.add_overlay (value);
			overlay.set_overlay_pass_through (value, true);
			scale.value_changed.connect (() => {
				value.label = "%.0f%%".printf (scale.get_value ());
				if (!updating_audio_controls)
					audio_service.set_volume (target, scale.get_value () / 100.0);
			});
			if (target == AudioTarget.OUTPUT) {
				output_volume_scale = scale;
				output_mute_button = icon;
				output_volume_label = value;
			} else {
				input_volume_scale = scale;
				input_mute_button = icon;
				input_volume_label = value;
			}
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

		Gtk.Widget device_selector (AudioTarget target)
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
			populate_audio_combo (combo, target);
			combo.notify["popup-shown"].connect (() => {
				device_popup_open = combo.popup_shown;
				if (!device_popup_open && visible) {
					sync_audio_devices ();
					Idle.add (() => { present (); return false; });
				}
			});
			combo.changed.connect (() => {
				if (!updating_audio_controls && combo.active_id != null)
					audio_service.set_default_device.begin (target, combo.active_id);
			});
			if (target == AudioTarget.OUTPUT)
				output_device_combo = combo;
			else
				input_device_combo = combo;
			row.pack_start (combo, true, true, 0);
			return row;
		}

		void populate_audio_combo (Gtk.ComboBoxText combo, AudioTarget target)
		{
			combo.remove_all ();
			foreach (AudioDevice device in audio_service.get_devices (target))
				combo.append (device.id, friendly_device_name (device.name));
			combo.active_id = audio_service.get_default_device (target);
		}

		string friendly_device_name (string name)
		{
			var result = name.replace ("alsa_output.", "").replace ("alsa_input.", "");
			result = result.replace ("bluez_output.", "Bluetooth · ").replace ("bluez_input.", "Bluetooth · ");
			result = result.replace ("_", " ").replace (".", " · ");
			return result;
		}

		void sync_audio_controls ()
		{
			if (current_item == null || current_item.Kind != StatusIndicatorKind.VOLUME)
				return;
			updating_audio_controls = true;
			update_audio_control (AudioTarget.OUTPUT, output_volume_scale,
				output_mute_button, output_volume_label);
			update_audio_control (AudioTarget.INPUT, input_volume_scale,
				input_mute_button, input_volume_label);
			updating_audio_controls = false;
		}

		void update_audio_control (AudioTarget target, Gtk.Scale? scale,
			Gtk.ToggleButton? mute_button, Gtk.Label? value_label)
		{
			var percent = audio_service.get_volume (target) * 100.0;
			if (scale != null && Math.fabs (scale.get_value () - percent) > 0.5)
				scale.set_value (percent);
			if (mute_button != null)
				mute_button.active = audio_service.is_muted (target);
			if (value_label != null)
				value_label.label = "%.0f%%".printf (percent);
		}

		void sync_audio_devices ()
		{
			if (device_popup_open || current_item == null
				|| current_item.Kind != StatusIndicatorKind.VOLUME)
				return;
			updating_audio_controls = true;
			if (output_device_combo != null)
				populate_audio_combo (output_device_combo, AudioTarget.OUTPUT);
			if (input_device_combo != null)
				populate_audio_combo (input_device_combo, AudioTarget.INPUT);
			updating_audio_controls = false;
		}

		void build_bluetooth ()
		{
			if (!bluetooth_service.available) {
				content.pack_start (info_row (_("Bluetooth is not available"),
					_("No Bluetooth adapter was found")), false, false, 0);
				add_bluetooth_settings_button ();
				return;
			}
			var powered = bluetooth_service.powered;
			var adapter_state = powered ? _("On") : _("Off");
			content.pack_start (switch_row (_("Bluetooth · %s").printf (adapter_state), powered, (state) => {
				if (!state)
					stop_bluetooth_discovery ();
				bluetooth_service.change_powered.begin (state);
			}, !bluetooth_service.busy), false, false, 0);
			if (!powered) {
				content.pack_start (info_row (_("Bluetooth is turned off"),
					_("Turn it on to see nearby devices")), false, false, 0);
				add_bluetooth_settings_button ();
				return;
			}

			var connected_count = 0;
			var known_count = 0;
			var nearby_count = 0;
			var connected_rows = new Gee.ArrayList<Gtk.Widget> ();
			var known_rows = new Gee.ArrayList<Gtk.Widget> ();
			var nearby_rows = new Gee.ArrayList<Gtk.Widget> ();
			foreach (BluetoothDevice device in bluetooth_service.get_devices ()) {
				var row = bluetooth_device_row (device);
				if (device.connected) { connected_rows.add (row); connected_count++; }
				else if (device.paired) { known_rows.add (row); known_count++; }
				else if (nearby_count < 3) { nearby_rows.add (row); nearby_count++; }
			}
			if (connected_count > 0) {
				content.pack_start (section_label (_("Connected")), false, false, 0);
				foreach (var row in connected_rows) content.pack_start (row, false, false, 0);
			}
			if (known_count > 0) {
				content.pack_start (section_label (_("Known devices")), false, false, 0);
				foreach (var row in known_rows) content.pack_start (row, false, false, 0);
			}
			if (nearby_count > 0) {
				content.pack_start (section_label (_("Nearby")), false, false, 0);
				foreach (var row in nearby_rows) content.pack_start (row, false, false, 0);
			}

			if (connected_count + known_count + nearby_count == 0)
				content.pack_start (info_row (_("No devices found"),
					bluetooth_service.discovering ? _("Searching for nearby devices")
						: _("Open this panel to search for nearby devices")), false, false, 0);

			add_bluetooth_settings_button ();
		}

		void start_bluetooth_discovery ()
		{
			if (bluetooth_service.powered && !bluetooth_discovery_owned) {
				bluetooth_discovery_owned = true;
				bluetooth_service.change_discovery (true);
			}
		}

		void stop_bluetooth_discovery ()
		{
			if (bluetooth_discovery_owned)
				bluetooth_service.change_discovery (false);
			bluetooth_discovery_owned = false;
		}

		Gtk.Widget bluetooth_device_row (BluetoothDevice device)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
			row.get_style_context ().add_class ("bluetooth-device-row");
			row.pack_start (new Gtk.Image.from_icon_name ("bluetooth-symbolic", Gtk.IconSize.BUTTON), false, false, 0);
			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			var title = new Gtk.Label (device.name) { xalign = 0.0f, ellipsize = Pango.EllipsizeMode.END };
			var state = device.connected ? _("Connected") : (device.paired ? _("Known device") : _("Nearby"));
			if (device.battery_percentage >= 0)
				state += " · %d%%".printf (device.battery_percentage);
			var subtitle = new Gtk.Label (state) { xalign = 0.0f };
			subtitle.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (title, false, false, 0);
			labels.pack_start (subtitle, false, false, 0);
			row.pack_start (labels, true, true, 0);
			var action = new Gtk.Button.with_label (device.connected ? _("Disconnect") : _("Connect"));
			action.get_style_context ().add_class ("bluetooth-device-action");
			action.sensitive = !bluetooth_service.busy;
			action.clicked.connect (() => {
				action.sensitive = false;
				bluetooth_service.set_connected.begin (device, !device.connected);
			});
			row.pack_end (action, false, false, 0);
			if (device.paired && !device.connected) {
				var forget = new Gtk.Button.from_icon_name ("edit-delete-symbolic", Gtk.IconSize.MENU);
				forget.tooltip_text = _("Forget device");
				forget.get_style_context ().add_class ("bluetooth-device-action");
				forget.sensitive = !bluetooth_service.busy;
				forget.clicked.connect (() => {
					forget.sensitive = false;
					bluetooth_service.remove_device.begin (device);
				});
				row.pack_end (forget, false, false, 0);
			}
			return row;
		}

		void bluetooth_service_changed ()
		{
			if (!visible || current_item == null || current_item.Kind != StatusIndicatorKind.BLUETOOTH)
				return;
			if (bluetooth_service.powered && !bluetooth_discovery_owned)
				start_bluetooth_discovery ();
			if (bluetooth_rebuild_id > 0U)
				Source.remove (bluetooth_rebuild_id);
			bluetooth_rebuild_id = Timeout.add (75, () => {
				bluetooth_rebuild_id = 0U;
				if (visible && current_item != null && current_item.Kind == StatusIndicatorKind.BLUETOOTH) {
					rebuild (StatusIndicatorKind.BLUETOOTH);
					show_all ();
				}
				return false;
			});
		}

		void add_bluetooth_settings_button ()
		{
			var settings = new Gtk.Button.with_label (_("Advanced Bluetooth settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("blueman-manager"));
			footer.pack_start (settings, false, false, 0);
		}

		void build_wifi ()
		{
			string output = "";
			var enabled = run ("nmcli radio wifi", out output) && output.strip () == "enabled";
			content.pack_start (switch_row (_("Wi-Fi · %s").printf (enabled ? _("On") : _("Off")), enabled, (state) => {
				run_action ("nmcli radio wifi " + (state ? "on" : "off"));
				if (state) start_wifi_refresh (); else stop_wifi_refresh ();
				rebuild_wifi_later (350);
			}), false, false, 0);
			if (!enabled) {
				content.pack_start (info_row (_("Wi-Fi is turned off"),
					_("Turn it on to see nearby networks")), false, false, 0);
				add_wifi_settings_button ();
				return;
			}

			var known = new Gee.HashSet<string> ();
			if (run ("nmcli -t -f NAME,TYPE connection show", out output))
				foreach (unowned string line in output.split ("\n")) {
					var separator = line.last_index_of_char (':');
					if (separator > 0 && line.substring (separator + 1) == "802-11-wireless")
						known.add (line.substring (0, separator).replace ("\\:", ":"));
				}

			string active_ssid = "";
			string ip_address = "";
			if (run ("nmcli -t -f ACTIVE,SSID device wifi", out output))
				foreach (unowned string line in output.split ("\n"))
					if (line.has_prefix ("yes:")) { active_ssid = line.substring (4).replace ("\\:", ":"); break; }
			if (run ("nmcli -g IP4.ADDRESS device show", out output))
				foreach (unowned string line in output.split ("\n"))
					if (line.strip () != "") { ip_address = line.strip ().split ("/")[0]; break; }

			var connected_rows = new Gee.ArrayList<Gtk.Widget> ();
			var known_rows = new Gee.ArrayList<Gtk.Widget> ();
			var nearby_rows = new Gee.ArrayList<Gtk.Widget> ();
			var seen = new Gee.HashSet<string> ();
			if (run ("nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan no", out output))
				foreach (unowned string line in output.split ("\n")) {
					var fields = line.split (":");
					if (fields.length < 4 || fields[1] == "") continue;
					var ssid = fields[1].replace ("\\:", ":");
					if (ssid in seen) continue;
					seen.add (ssid);
					var connected = fields[0] == "*" || ssid == active_ssid;
					var saved = ssid in known;
					var secure = fields[3] != "" && fields[3] != "--";
					var row = wifi_network_row (ssid, fields[2], secure, connected, saved,
						connected ? ip_address : "");
					if (connected) connected_rows.add (row);
					else if (saved) known_rows.add (row);
					else nearby_rows.add (row);
				}

			if (connected_rows.size > 0) {
				content.pack_start (section_label (_("Connected")), false, false, 0);
				foreach (var row in connected_rows) content.pack_start (row, false, false, 0);
			}
			var available = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			available.get_style_context ().add_class ("wifi-networks-list");
			if (known_rows.size > 0) {
				available.pack_start (section_label (_("Known networks")), false, false, 0);
				foreach (var row in known_rows) available.pack_start (row, false, false, 0);
			}
			if (nearby_rows.size > 0) {
				available.pack_start (section_label (_("Nearby networks")), false, false, 0);
				foreach (var row in nearby_rows) available.pack_start (row, false, false, 0);
			}
			if (known_rows.size + nearby_rows.size == 0)
				available.pack_start (info_row (_("No networks found"), _("Scanning for nearby networks…")), false, false, 0);
			var networks_scroll = new Gtk.ScrolledWindow (null, null);
			networks_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
			networks_scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
			networks_scroll.overlay_scrolling = true;
			networks_scroll.height_request = connected_rows.size > 0 ? 205 : 270;
			networks_scroll.get_style_context ().add_class ("wifi-networks-scroll");
			networks_scroll.add (available);
			content.pack_start (networks_scroll, true, true, 0);
			add_wifi_settings_button ();
		}

		Gtk.Widget wifi_network_row (string ssid, string signal, bool secure,
			bool connected, bool known, string ip_address)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
			row.get_style_context ().add_class ("wifi-network-row");
			row.pack_start (new Gtk.Image.from_icon_name (wifi_signal_icon (signal), Gtk.IconSize.BUTTON), false, false, 0);
			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			var title = new Gtk.Label (ssid) { xalign = 0.0f, ellipsize = Pango.EllipsizeMode.END };
			var detail = connected ? _("Connected") : _("Signal %s%%").printf (signal);
			if (connected && ip_address != "") detail += " · " + ip_address;
			if (secure) detail += " · " + _("Secured");
			var subtitle = new Gtk.Label (detail) { xalign = 0.0f };
			subtitle.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (title, false, false, 0);
			labels.pack_start (subtitle, false, false, 0);
			row.pack_start (labels, true, true, 0);
			var action = new Gtk.Button.with_label (connected ? _("Disconnect") : _("Connect"));
			action.get_style_context ().add_class ("wifi-network-action");
			action.clicked.connect (() => {
				action.sensitive = false;
				if (connected)
					launch ("nmcli connection down id " + Shell.quote (ssid));
				else if (known)
					launch ("nmcli connection up id " + Shell.quote (ssid));
				else if (secure)
					prompt_wifi_password (ssid);
				else
					launch ("nmcli device wifi connect " + Shell.quote (ssid));
				rebuild_wifi_later (1800);
			});
			row.pack_end (action, false, false, 0);
			if (known && !connected) {
				var forget = new Gtk.Button.from_icon_name ("edit-delete-symbolic", Gtk.IconSize.MENU);
				forget.tooltip_text = _("Forget network");
				forget.get_style_context ().add_class ("wifi-network-action");
				forget.clicked.connect (() => {
					run_action ("nmcli connection delete id " + Shell.quote (ssid));
					rebuild_wifi_later (300);
				});
				row.pack_end (forget, false, false, 0);
			}
			return row;
		}

		string wifi_signal_icon (string signal)
		{
			var value = int.parse (signal);
			if (value >= 75) return "network-wireless-signal-excellent-symbolic";
			if (value >= 50) return "network-wireless-signal-good-symbolic";
			if (value >= 25) return "network-wireless-signal-ok-symbolic";
			return "network-wireless-signal-weak-symbolic";
		}

		void prompt_wifi_password (string ssid)
		{
			device_popup_open = true;
			var dialog = new Gtk.Dialog.with_buttons (_("Connect to %s").printf (ssid), this,
				Gtk.DialogFlags.MODAL, _("Cancel"), Gtk.ResponseType.CANCEL,
				_("Connect"), Gtk.ResponseType.OK);
			var entry = new Gtk.Entry ();
			entry.visibility = false;
			entry.activates_default = true;
			entry.placeholder_text = _("Wi-Fi password");
			entry.margin = 12;
			dialog.get_content_area ().pack_start (entry, false, false, 0);
			dialog.set_default_response (Gtk.ResponseType.OK);
			dialog.response.connect ((response) => {
				if (response == Gtk.ResponseType.OK && entry.text != "")
					launch ("nmcli device wifi connect " + Shell.quote (ssid)
						+ " password " + Shell.quote (entry.text));
				dialog.destroy ();
				device_popup_open = false;
				rebuild_wifi_later (1800);
			});
			dialog.show_all ();
		}

		void start_wifi_refresh ()
		{
			if (wifi_refresh_id > 0U || !contains ("nmcli radio wifi", "enabled")) return;
			launch ("nmcli device wifi rescan");
			wifi_refresh_id = Timeout.add (5000, () => {
				if (!visible || current_item == null || current_item.Kind != StatusIndicatorKind.WIFI) {
					wifi_refresh_id = 0U;
					return false;
				}
				launch ("nmcli device wifi rescan");
				rebuild (StatusIndicatorKind.WIFI);
				show_all ();
				return true;
			});
		}

		void stop_wifi_refresh ()
		{
			if (wifi_refresh_id > 0U) { Source.remove (wifi_refresh_id); wifi_refresh_id = 0U; }
		}

		void rebuild_wifi_later (uint delay)
		{
			Timeout.add (delay, () => {
				if (visible && current_item != null && current_item.Kind == StatusIndicatorKind.WIFI) {
					rebuild (StatusIndicatorKind.WIFI);
					show_all ();
				}
				return false;
			});
		}

		void add_wifi_settings_button ()
		{
			var settings = new Gtk.Button.with_label (_("Advanced network settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("nm-connection-editor"));
			footer.pack_start (settings, false, false, 0);
		}

		void build_battery ()
		{
			var battery = find_power_supply ("BAT");
			if (battery == "") {
				content.pack_start (info_row (_("No battery detected"),
					_("This device may be running on external power")), false, false, 0);
				add_power_settings_button ();
				return;
			}

			var percent = read_sys_int (battery + "/capacity");
			var status = read_sys (battery + "/status");
			var charge_now = read_sys_int64 (battery + "/charge_now");
			var charge_full = read_sys_int64 (battery + "/charge_full");
			var charge_design = read_sys_int64 (battery + "/charge_full_design");
			var current = read_sys_int64 (battery + "/current_now");
			var voltage = read_sys_int64 (battery + "/voltage_now");
			var cycles = read_sys_int (battery + "/cycle_count");

			var summary = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
			summary.get_style_context ().add_class ("battery-summary");
			var percentage = new Gtk.Label ("%d%%".printf (percent));
			percentage.get_style_context ().add_class ("battery-percentage");
			summary.pack_start (percentage, false, false, 0);
			var estimate = battery_time_text (status, charge_now, charge_full, current);
			var status_label = new Gtk.Label (estimate == "" ? translated_battery_status (status) : estimate);
			status_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			summary.pack_start (status_label, false, false, 0);
			content.pack_start (summary, false, false, 0);

			content.pack_start (section_label (_("Energy")), false, false, 0);
			var power = current > 0 && voltage > 0 ? current * voltage / 1000000000000.0 : 0.0;
			content.pack_start (metric_row (_("Current consumption"),
				power > 0.01 ? "%.1f W".printf (power) : _("Not available")), false, false, 0);
			var health = charge_design > 0 ? 100.0 * charge_full / charge_design : 0.0;
			content.pack_start (metric_row (_("Battery health"),
				health > 0 ? "%.0f%%".printf (health) : _("Not available")), false, false, 0);
			content.pack_start (metric_row (_("Charge cycles"),
				cycles >= 0 ? "%d".printf (cycles) : _("Not available")), false, false, 0);

			build_power_profiles ();
			build_brightness_control ();
			add_power_settings_button ();
		}

		Gtk.Widget metric_row (string label, string value)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
			row.get_style_context ().add_class ("battery-metric-row");
			row.pack_start (new Gtk.Label (label) { xalign = 0.0f }, true, true, 0);
			var result = new Gtk.Label (value) { xalign = 1.0f };
			result.get_style_context ().add_class ("battery-metric-value");
			row.pack_end (result, false, false, 0);
			return row;
		}

		void build_power_profiles ()
		{
			string current = "";
			if (!run ("powerprofilesctl get", out current))
				return;
			content.pack_start (section_label (_("Power profile")), false, false, 0);
			var profiles = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
			profiles.get_style_context ().add_class ("power-profiles");
			string[] profile_ids = { "power-saver", "balanced", "performance" };
			Gtk.RadioButton? first_profile = null;
			foreach (unowned string id in profile_ids) {
				var button = first_profile == null
					? new Gtk.RadioButton.with_label (null, profile_label (id))
					: new Gtk.RadioButton.with_label_from_widget (first_profile, profile_label (id));
				if (first_profile == null) first_profile = button;
				button.active = current.strip () == id;
				button.get_style_context ().add_class ("power-profile-button");
				button.toggled.connect (() => {
					if (button.active) run_action ("powerprofilesctl set " + id);
				});
				profiles.pack_start (button, true, true, 0);
			}
			content.pack_start (profiles, false, false, 0);
		}

		void build_brightness_control ()
		{
			var backlight = first_directory ("/sys/class/backlight");
			if (backlight == "") return;
			var brightness = read_sys_int (backlight + "/brightness");
			var maximum = read_sys_int (backlight + "/max_brightness");
			if (maximum <= 0) return;
			content.pack_start (section_label (_("Screen brightness")), false, false, 0);
			var overlay = new Gtk.Overlay ();
			overlay.get_style_context ().add_class ("modern-volume-bar");
			var scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 5, 100, 1);
			scale.draw_value = false;
			scale.has_origin = true;
			scale.height_request = 36;
			scale.set_value (100.0 * brightness / maximum);
			scale.get_style_context ().add_class ("modern-volume-scale");
			overlay.add (scale);
			scale.button_release_event.connect (() => {
				var target = (int) (maximum * scale.get_value () / 100.0);
				launch ("pkexec /usr/sbin/xfpm-power-backlight-helper --set-brightness " + target.to_string ());
				return false;
			});
			var icon = new Gtk.Image.from_icon_name ("display-brightness-symbolic", Gtk.IconSize.MENU);
			icon.halign = Gtk.Align.START;
			icon.valign = Gtk.Align.CENTER;
			icon.margin_start = 10;
			overlay.add_overlay (icon);
			overlay.set_overlay_pass_through (icon, true);
			var value = new Gtk.Label ("%.0f%%".printf (scale.get_value ())) { width_request = 38, xalign = 1.0f };
			value.halign = Gtk.Align.END;
			value.valign = Gtk.Align.CENTER;
			value.margin_end = 10;
			value.get_style_context ().add_class ("modern-volume-value");
			scale.value_changed.connect (() => value.label = "%.0f%%".printf (scale.get_value ()));
			overlay.add_overlay (value);
			overlay.set_overlay_pass_through (value, true);
			content.pack_start (overlay, false, false, 0);
		}

		string battery_time_text (string status, int64 now, int64 full, int64 current)
		{
			if (current <= 0) return "";
			var amount = status == "Charging" ? full - now : now;
			if (amount <= 0) return "";
			var minutes = (int) Math.round (60.0 * amount / current);
			var time = _("%d h %02d min").printf (minutes / 60, minutes % 60);
			return status == "Charging" ? _("%s until full").printf (time) : _("%s remaining").printf (time);
		}

		string translated_battery_status (string status)
		{
			switch (status) {
			case "Charging": return _("Charging");
			case "Discharging": return _("On battery");
			case "Full": return _("Fully charged");
			default: return status;
			}
		}

		string profile_label (string id)
		{
			switch (id) {
			case "power-saver": return _("Saver");
			case "performance": return _("Performance");
			default: return _("Balanced");
			}
		}

		void add_power_settings_button ()
		{
			var settings = new Gtk.Button.with_label (_("Advanced power settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("xfce4-power-manager-settings"));
			footer.pack_start (settings, false, false, 0);
		}

		static string find_power_supply (string prefix)
		{
			try {
				var directory = Dir.open ("/sys/class/power_supply");
				string? name;
				while ((name = directory.read_name ()) != null)
					if (name.has_prefix (prefix)) return "/sys/class/power_supply/" + name;
			} catch (FileError e) {}
			return "";
		}

		static string first_directory (string path)
		{
			try {
				var directory = Dir.open (path);
				string? name;
				while ((name = directory.read_name ()) != null)
					if (!name.has_prefix (".")) return path + "/" + name;
			} catch (FileError e) {}
			return "";
		}

		static string read_sys (string path)
		{
			string value = "";
			try { FileUtils.get_contents (path, out value); } catch (FileError e) {}
			return value.strip ();
		}

		static int read_sys_int (string path)
		{
			var value = read_sys (path);
			return value == "" ? -1 : int.parse (value);
		}

		static int64 read_sys_int64 (string path)
		{
			var value = read_sys (path);
			return value == "" ? -1 : int64.parse (value);
		}

		void build_clock ()
		{
			var now = new DateTime.now_local ();
			var stack = new Gtk.Stack ();
			stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
			stack.transition_duration = 120;
			stack.get_style_context ().add_class ("clock-stack");
			var switcher = new Gtk.StackSwitcher ();
			switcher.stack = stack;
			switcher.homogeneous = true;
			switcher.get_style_context ().add_class ("clock-tabs");
			content.pack_start (switcher, false, false, 0);
			content.pack_start (stack, true, true, 0);

			var time_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
			time_page.get_style_context ().add_class ("clock-page");
			var summary = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			summary.get_style_context ().add_class ("clock-summary");
			clock_time_label = new Gtk.Label (now.format ("%H:%M:%S"));
			clock_time_label.get_style_context ().add_class ("clock-time");
			clock_date_label = new Gtk.Label (now.format ("%A, %e %B %Y"));
			clock_date_label.get_style_context ().add_class ("clock-date");
			clock_zone_label = new Gtk.Label (timezone_name (now));
			clock_zone_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			summary.pack_start (clock_time_label, false, false, 0);
			summary.pack_start (clock_date_label, false, false, 0);
			summary.pack_start (clock_zone_label, false, false, 0);
			time_page.pack_start (summary, true, true, 0);
			var copy = new Gtk.Button.with_label (_("Copy date and time"));
			copy.get_style_context ().add_class ("status-action-button");
			copy.clicked.connect (() => {
				Gtk.Clipboard.get (Gdk.SELECTION_CLIPBOARD).set_text (
					new DateTime.now_local ().format ("%Y-%m-%d %H:%M:%S"), -1);
			});
			time_page.pack_end (copy, false, false, 0);
			stack.add_titled (time_page, "time", _("Time"));

			var calendar_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
			calendar_page.get_style_context ().add_class ("clock-page");
			var calendar = new Gtk.Calendar ();
			calendar.show_heading = true;
			calendar.show_day_names = true;
			calendar.get_style_context ().add_class ("clock-calendar");
			calendar_page.pack_start (calendar, true, true, 0);
			stack.add_titled (calendar_page, "calendar", _("Calendar"));

			var pomodoro_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
			pomodoro_page.get_style_context ().add_class ("clock-page");
			var pomodoro_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
			var pomodoro_title = new Gtk.Label (_("Pomodoro focus"));
			pomodoro_title.get_style_context ().add_class ("clock-tool-title");
			pomodoro_box.pack_start (pomodoro_title, false, false, 0);
			var mode_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 5);
			mode_row.halign = Gtk.Align.CENTER;
			var focus_mode = new Gtk.RadioButton.with_label (null, _("Focus · 25 min"));
			var break_mode = new Gtk.RadioButton.with_label_from_widget (focus_mode, _("Break · 5 min"));
			var long_break_mode = new Gtk.RadioButton.with_label_from_widget (focus_mode, _("Long · 15 min"));
			focus_mode.active = pomodoro_mode == 0;
			break_mode.active = pomodoro_mode == 1;
			long_break_mode.active = pomodoro_mode == 2;
			focus_mode.get_style_context ().add_class ("clock-tool-button");
			break_mode.get_style_context ().add_class ("clock-tool-button");
			long_break_mode.get_style_context ().add_class ("clock-tool-button");
			mode_row.pack_start (focus_mode, false, false, 0);
			mode_row.pack_start (break_mode, false, false, 0);
			mode_row.pack_start (long_break_mode, false, false, 0);
			pomodoro_box.pack_start (mode_row, false, false, 0);
			countdown_label = new Gtk.Label (format_duration (countdown_seconds > 0 ? countdown_seconds : 25 * 60));
			countdown_label.get_style_context ().add_class ("clock-counter");
			pomodoro_box.pack_start (countdown_label, true, true, 0);
			var pomodoro_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
			pomodoro_actions.halign = Gtk.Align.CENTER;
			var start_button = new Gtk.Button.with_label (countdown_tick_id > 0U ? _("Pause") : _("Start"));
			countdown_button = start_button;
			start_button.get_style_context ().add_class ("clock-tool-button");
			start_button.clicked.connect (() => {
				if (countdown_tick_id > 0U) {
					pause_countdown ();
					start_button.label = _("Start");
				} else {
					if (countdown_seconds == 0)
						countdown_seconds = pomodoro_duration ();
					resume_countdown ();
					start_button.label = _("Pause");
				}
			});
			var reset = new Gtk.Button.from_icon_name ("view-refresh-symbolic", Gtk.IconSize.MENU);
			reset.tooltip_text = _("Reset Pomodoro");
			reset.get_style_context ().add_class ("clock-tool-button");
			reset.clicked.connect (() => {
				stop_countdown ();
				countdown_seconds = pomodoro_duration ();
				if (countdown_label != null) countdown_label.label = format_duration (countdown_seconds);
				start_button.label = _("Start");
			});
			focus_mode.toggled.connect (() => {
				if (!focus_mode.active) return;
				pomodoro_mode = 0;
				stop_countdown (); countdown_seconds = 25 * 60;
				countdown_label.label = format_duration (countdown_seconds);
				start_button.label = _("Start");
			});
			break_mode.toggled.connect (() => {
				if (!break_mode.active) return;
				pomodoro_mode = 1;
				stop_countdown (); countdown_seconds = 5 * 60;
				countdown_label.label = format_duration (countdown_seconds);
				start_button.label = _("Start");
			});
			long_break_mode.toggled.connect (() => {
				if (!long_break_mode.active) return;
				pomodoro_mode = 2;
				stop_countdown (); countdown_seconds = 15 * 60;
				countdown_label.label = format_duration (countdown_seconds);
				start_button.label = _("Start");
			});
			pomodoro_actions.pack_start (start_button, false, false, 0);
			pomodoro_actions.pack_start (reset, false, false, 0);
			pomodoro_box.pack_end (pomodoro_actions, false, false, 0);
			pomodoro_page.pack_start (pomodoro_box, true, true, 0);
			stack.add_titled (pomodoro_page, "pomodoro", _("Pomodoro"));
		}

		void start_clock_display ()
		{
			stop_clock_display ();
			update_clock_labels ();
			clock_display_tick_id = Timeout.add_seconds (1, () => {
				if (!visible || current_item == null || current_item.Kind != StatusIndicatorKind.CLOCK) {
					clock_display_tick_id = 0U;
					return false;
				}
				update_clock_labels ();
				return true;
			});
		}

		void stop_clock_display ()
		{
			if (clock_display_tick_id > 0U) {
				Source.remove (clock_display_tick_id);
				clock_display_tick_id = 0U;
			}
		}

		void update_clock_labels ()
		{
			var now = new DateTime.now_local ();
			if (clock_time_label != null) clock_time_label.label = now.format ("%H:%M:%S");
			if (clock_date_label != null) clock_date_label.label = now.format ("%A, %e %B %Y");
			if (clock_zone_label != null) clock_zone_label.label = timezone_name (now);
		}

		void start_countdown (int seconds)
		{
			stop_countdown ();
			countdown_seconds = seconds;
			resume_countdown ();
		}

		void resume_countdown ()
		{
			if (countdown_seconds <= 0 || countdown_tick_id > 0U)
				return;
			if (countdown_label != null) countdown_label.label = format_duration (countdown_seconds);
			countdown_tick_id = Timeout.add_seconds (1, () => {
				countdown_seconds--;
				if (countdown_label != null) countdown_label.label = format_duration (int.max (0, countdown_seconds));
				if (countdown_seconds > 0) return true;
				countdown_tick_id = 0U;
				if (countdown_button != null) countdown_button.label = _("Start");
				launch ("notify-send " + Shell.quote (_("Pomodoro finished")) + " "
					+ Shell.quote (_("The current focus or break session has finished.")));
				return false;
			});
		}

		void pause_countdown ()
		{
			if (countdown_tick_id > 0U) {
				Source.remove (countdown_tick_id);
				countdown_tick_id = 0U;
			}
		}

		void stop_countdown ()
		{
			if (countdown_tick_id > 0U) {
				Source.remove (countdown_tick_id);
				countdown_tick_id = 0U;
			}
			countdown_seconds = 0;
			if (countdown_label != null) countdown_label.label = _("Timer");
		}

		void toggle_stopwatch ()
		{
			stopwatch_running = !stopwatch_running;
			if (!stopwatch_running) {
				if (stopwatch_tick_id > 0U) Source.remove (stopwatch_tick_id);
				stopwatch_tick_id = 0U;
				return;
			}
			stopwatch_tick_id = Timeout.add_seconds (1, () => {
				if (!stopwatch_running) { stopwatch_tick_id = 0U; return false; }
				stopwatch_seconds++;
				if (stopwatch_label != null) stopwatch_label.label = format_duration (stopwatch_seconds);
				return true;
			});
		}

		string timezone_name (DateTime now)
		{
			var zone = Environment.get_variable ("TZ");
			return zone != null && zone != "" ? zone : now.format ("%Z · UTC%:z");
		}

		string format_duration (int seconds)
		{
			return "%02d:%02d".printf (seconds / 60, seconds % 60);
		}

		int pomodoro_duration ()
		{
			return pomodoro_mode == 0 ? 25 * 60 : (pomodoro_mode == 1 ? 5 * 60 : 15 * 60);
		}

		delegate void SwitchChanged (bool state);
		Gtk.Widget switch_row (string label, bool state, owned SwitchChanged changed,
			bool sensitive = true)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			row.get_style_context ().add_class ("status-row");
			row.pack_start (new Gtk.Label (label) { xalign = 0.0f }, true, true, 0);
			var toggle = new Gtk.Switch () { active = state, valign = Gtk.Align.CENTER };
			toggle.sensitive = sensitive;
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
			css += ".plank-status-panel .status-card { background-color: rgb(%d,%d,%d); border: 1px solid rgba(255,255,255,0.10); border-radius: 12px; padding: 7px; }"
				.printf ((int)(color.red*255), (int)(color.green*255), (int)(color.blue*255));
			css += ".plank-status-panel .status-title { padding: 5px 7px; color: white; }";
			css += ".plank-status-panel .status-title-label { font-weight: bold; font-size: 15px; }";
			css += ".plank-status-panel .status-row { color: white; padding: 4px 6px; border-radius: 8px; }";
			css += ".plank-status-panel .status-section-label { color: rgba(255,255,255,0.58); font-size: 10px; font-weight: bold; margin: 4px 6px 0 6px; }";
			css += ".plank-status-panel .status-action-button { color: white; background-color: rgba(255,255,255,0.08); background-image: none; border: none; border-radius: 8px; box-shadow: none; padding: 5px; margin-top: 4px; }";
			css += ".plank-status-panel .bluetooth-device-row { color: white; padding: 7px 6px; border-radius: 9px; background-color: rgba(255,255,255,0.05); margin: 2px 3px; }";
			css += ".plank-status-panel .bluetooth-device-row:hover { background-color: rgba(255,255,255,0.08); }";
			css += ".plank-status-panel .bluetooth-device-action { color: white; background-color: rgba(255,255,255,0.09); background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px 7px; }";
			css += ".plank-status-panel .bluetooth-device-action:hover { background-color: rgba(255,255,255,0.14); }";
			css += ".plank-status-panel .wifi-network-row { color: white; padding: 7px 6px; border-radius: 9px; background-color: rgba(255,255,255,0.05); margin: 2px 3px; }";
			css += ".plank-status-panel .wifi-network-row:hover { background-color: rgba(255,255,255,0.08); }";
			css += ".plank-status-panel .wifi-network-action { color: white; background-color: rgba(255,255,255,0.09); background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px 7px; }";
			css += ".plank-status-panel .wifi-network-action:hover { background-color: rgba(255,255,255,0.14); }";
			css += ".plank-status-panel .wifi-networks-scroll, .plank-status-panel .wifi-networks-list { background: transparent; border: none; box-shadow: none; }";
			css += ".plank-status-panel .wifi-networks-scroll scrollbar { background: transparent; border: none; }";
			css += ".plank-status-panel .wifi-networks-scroll scrollbar slider { min-width: 4px; min-height: 28px; background-color: rgba(255,255,255,0.20); border-radius: 4px; }";
			css += ".plank-status-panel .battery-summary { color: white; padding: 8px 10px; }";
			css += ".plank-status-panel .battery-percentage { color: white; font-size: 34px; font-weight: bold; }";
			css += ".plank-status-panel .battery-metric-row { color: white; padding: 3px 7px; }";
			css += ".plank-status-panel .battery-metric-value { color: rgba(255,255,255,0.72); font-weight: bold; }";
			css += ".plank-status-panel .power-profiles { margin: 2px 5px; }";
			css += ".plank-status-panel .power-profile-button { color: rgba(255,255,255,0.70); background: rgba(255,255,255,0.06); background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px; }";
			css += ".plank-status-panel .power-profile-button:checked { color: white; background-color: rgba(115,210,22,0.28); }";
			css += ".plank-status-panel .clock-summary { color: white; padding: 3px 8px 5px 8px; }";
			css += ".plank-status-panel .clock-tabs { margin: 2px 5px 6px 5px; }";
			css += ".plank-status-panel .clock-tabs button { color: rgba(255,255,255,0.65); background: transparent; background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px 3px; font-size: 9px; }";
			css += ".plank-status-panel .clock-tabs button:checked { color: white; background-color: rgba(255,255,255,0.13); }";
			css += ".plank-status-panel .clock-page { color: white; padding: 5px 8px; }";
			css += ".plank-status-panel .clock-time { color: white; font-size: 31px; font-weight: bold; }";
			css += ".plank-status-panel .clock-date { color: rgba(255,255,255,0.86); font-weight: bold; }";
			css += ".plank-status-panel .clock-calendar { color: white; padding: 2px; }";
			css += ".plank-status-panel .clock-tools { color: white; margin: 3px 5px; }";
			css += ".plank-status-panel .clock-tools spinbutton { color: white; background-color: rgba(255,255,255,0.07); border: none; border-radius: 7px; }";
			css += ".plank-status-panel .clock-tool-button { color: white; background-color: rgba(255,255,255,0.09); background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px 7px; }";
			css += ".plank-status-panel .clock-tool-button:hover { background-color: rgba(255,255,255,0.14); }";
			css += ".plank-status-panel .clock-tool-title { color: rgba(255,255,255,0.72); font-size: 13px; font-weight: bold; }";
			css += ".plank-status-panel .clock-counter { color: white; font-size: 32px; font-weight: bold; }";
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
