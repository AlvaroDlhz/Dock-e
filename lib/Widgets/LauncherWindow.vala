//
// Native application launcher window.
//

namespace Plank
{
	public class LauncherWindow : Gtk.Window
	{
		const int RESULT_LIMIT = 9;
		const int PANEL_WIDTH = 480;
		const int PANEL_HEIGHT = 580;
		const int PANEL_GAP = 10;
		const int ANIMATION_TIME = 140;

		unowned DockController controller;
		Gtk.Entry search_entry;
		Gtk.ListBox result_list;
		Gtk.ToggleButton frequent_tab;
		Gtk.ToggleButton all_tab;
		Gtk.Menu power_menu;
		Gee.ArrayList<AppInfo> applications;
		Gee.ArrayList<AppInfo> visible_results;
		Gee.HashMap<string, int> usage_counts;
		LauncherItem? anchor_item;
		Gtk.CssProvider? theme_provider;
		uint animation_timer_id = 0U;
		int panel_x = 0;
		int panel_y = 0;
		bool showing_all = false;
		bool changing_tab = false;
		bool context_menu_open = false;
		bool context_dialog_open = false;
		Gtk.Window? application_context;
		ApplicationUninstallService uninstall_service;
		Cancellable? uninstall_detection;

		public LauncherWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			applications = new Gee.ArrayList<AppInfo> ();
			visible_results = new Gee.ArrayList<AppInfo> ();
			usage_counts = new Gee.HashMap<string, int> ();
			uninstall_service = new ApplicationUninstallService ();

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
			var rgba_visual = get_screen ().get_rgba_visual ();
			if (rgba_visual != null)
				set_visual (rgba_visual);
			get_style_context ().add_class ("plank-native-launcher");

			var panel = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
			panel.margin = 10;
			panel.get_style_context ().add_class ("launcher-panel");
			add (panel);

			var navbar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
			navbar.get_style_context ().add_class ("launcher-navbar");
			var power_button = new Gtk.Button ();
			power_button.tooltip_text = _("Session and power options");
			power_button.get_style_context ().add_class ("launcher-power-button");
			power_button.add (new Gtk.Image.from_icon_name ("system-shutdown-symbolic", Gtk.IconSize.BUTTON));
			power_menu = create_power_menu ();
			power_menu.show.connect (() => {
				controller.hide_manager.ExternalMenuVisible = true;
				controller.hide_manager.update_hovered ();
			});
			power_menu.hide.connect (() => {
				controller.hide_manager.ExternalMenuVisible = false;
				controller.hide_manager.update_hovered ();
			});
			power_button.clicked.connect (() => {
				power_menu.popup_at_widget (power_button, Gdk.Gravity.SOUTH_EAST,
					Gdk.Gravity.NORTH_EAST, null);
			});
			navbar.pack_end (power_button, false, false, 0);
			panel.pack_start (navbar, false, false, 0);

			var tabs = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
			tabs.get_style_context ().add_class ("launcher-tabs");
			frequent_tab = new Gtk.ToggleButton.with_label (_("Frequently used"));
			all_tab = new Gtk.ToggleButton.with_label (_("All"));
			frequent_tab.active = true;
			frequent_tab.clicked.connect (() => select_tab (false));
			all_tab.clicked.connect (() => select_tab (true));
			tabs.pack_start (frequent_tab, true, true, 0);
			tabs.pack_start (all_tab, true, true, 0);
			panel.pack_start (tabs, false, false, 0);

			result_list = new Gtk.ListBox ();
			result_list.selection_mode = Gtk.SelectionMode.SINGLE;
			result_list.activate_on_single_click = true;
			result_list.row_activated.connect ((row) => activate_row (row));
			result_list.button_press_event.connect ((event) => {
				if (event.button != 3U)
					return false;
				var row = result_list.get_row_at_y ((int) event.y);
				if (row == null || row.get_index () < 0 || row.get_index () >= visible_results.size)
					return false;
				result_list.select_row (row);
				show_application_context_menu (visible_results[row.get_index ()], event);
				return true;
			});
			var result_scroll = new Gtk.ScrolledWindow (null, null);
			result_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
			result_scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
			result_scroll.overlay_scrolling = true;
			result_scroll.get_style_context ().add_class ("launcher-results-scroll");
			result_scroll.add (result_list);
			panel.pack_start (result_scroll, true, true, 0);

			var search_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			search_box.margin = 10;
			search_box.get_style_context ().add_class ("launcher-search");
			search_entry = new Gtk.Entry ();
			search_entry.placeholder_text = _("Search applications…");
			search_entry.has_frame = false;
			search_entry.changed.connect (refresh_results);
			search_entry.focus_in_event.connect (() => {
				search_box.get_style_context ().add_class ("launcher-search-focused");
				return false;
			});
			search_entry.focus_out_event.connect (() => {
				search_box.get_style_context ().remove_class ("launcher-search-focused");
				return false;
			});
			search_box.pack_start (search_entry, true, true, 0);
			panel.pack_end (search_box, false, false, 0);

			key_press_event.connect (handle_key_press);
			focus_out_event.connect (() => {
				if (!power_menu.visible && !context_menu_open)
					hide_animated ();
				return false;
			});
			index_applications ();
			load_usage ();
			Matcher.get_default ().active_application_changed.connect_after (track_active_application);
		}

		~LauncherWindow ()
		{
			if (uninstall_detection != null)
				uninstall_detection.cancel ();
			if (animation_timer_id > 0U)
				Source.remove (animation_timer_id);
			if (theme_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), theme_provider);
			Matcher.get_default ().active_application_changed.disconnect (track_active_application);
		}

		void select_tab (bool all)
		{
			if (changing_tab)
				return;
			changing_tab = true;
			showing_all = all;
			frequent_tab.active = !all;
			all_tab.active = all;
			changing_tab = false;
			refresh_results ();
		}

		Gtk.Menu create_power_menu ()
		{
			var menu = new Gtk.Menu ();
			menu.get_style_context ().add_class ("plank-power-menu");
			menu.append (create_power_item (_("Lock"), "system-lock-screen-symbolic",
				"xflock4"));
			menu.append (create_power_item (_("Suspend"), "media-playback-pause-symbolic",
				"xfce4-session-logout --suspend"));
			menu.append (new Gtk.SeparatorMenuItem ());
			menu.append (create_power_item (_("Log out"), "system-log-out-symbolic",
				"xfce4-session-logout --logout"));
			menu.append (create_power_item (_("Restart"), "system-reboot-symbolic",
				"xfce4-session-logout --reboot"));
			menu.append (create_power_item (_("Power off"), "system-shutdown-symbolic",
				"xfce4-session-logout --halt"));
			menu.show_all ();
			return menu;
		}

		Gtk.MenuItem create_power_item (string title, string icon_name, string command)
		{
			var item = new Gtk.MenuItem ();
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			box.pack_start (new Gtk.Image.from_icon_name (icon_name, Gtk.IconSize.MENU), false, false, 0);
			box.pack_start (new Gtk.Label (title) { xalign = 0.0f }, true, true, 0);
			item.add (box);
			item.activate.connect (() => run_session_action (command));
			return item;
		}

		void run_session_action (string command)
		{
			try {
				Process.spawn_command_line_async (command);
			} catch (SpawnError e) {
				warning ("Unable to run session action: %s", e.message);
			}
		}

		void index_applications ()
		{
			applications.clear ();
			var seen = new Gee.HashSet<string> ();
			foreach (unowned AppInfo app in AppInfo.get_all ()) {
				var id = app.get_id () ?? app.get_name ();
				if (!app.should_show () || !application_is_available (app) || id in seen)
					continue;
				seen.add (id);
				applications.add (app);
			}
			applications.sort ((a, b) => a.get_display_name ().collate (b.get_display_name ()));
		}

		bool application_is_available (AppInfo app)
		{
			var executable = app.get_executable ();
			if (executable == null || executable.strip () == "")
				return false;
			try {
				string[] arguments;
				Shell.parse_argv (executable, out arguments);
				if (arguments.length == 0)
					return false;
				if (Path.is_absolute (arguments[0]))
					return FileUtils.test (arguments[0], FileTest.EXISTS | FileTest.IS_EXECUTABLE);
				return Environment.find_program_in_path (arguments[0]) != null;
			} catch (ShellError e) {
				return false;
			}
		}

		public void toggle (LauncherItem item)
		{
			if (visible) {
				hide_animated ();
				return;
			}
			show_for_item (item);
		}

		public void dismiss ()
		{
			dismiss_application_context ();
			hide_animated ();
		}

		public void dismiss_application_context ()
		{
			if (application_context != null && application_context.visible)
				application_context.hide ();
		}

		public void show_for_item (LauncherItem item)
		{
			anchor_item = item;
			index_applications ();
			search_entry.text = "";
			refresh_results ();
			apply_theme ();
			opacity = 0.0;
			show_all ();
			controller.renderer.animated_draw ();
			present ();
			search_entry.grab_focus ();
			Idle.add (() => {
				position_over_anchor ();
				move (panel_x, panel_y + 8);
				animate_to (1.0, false);
				return false;
			});
		}

		void refresh_results ()
		{
			foreach (unowned Gtk.Widget child in result_list.get_children ())
				result_list.remove (child);
			visible_results.clear ();

			var query = search_entry.text.strip ().down ();
			var matches = new Gee.ArrayList<AppInfo> ();
			foreach (var app in applications)
				if ((query != "" || showing_all || usage_count (app) > 0)
					&& (query == "" || fuzzy_score (searchable_text (app), query) >= 0))
					matches.add (app);
			matches.sort ((a, b) => compare_results (a, b, query));

			var result_count = (showing_all || query != "") ? matches.size : int.min (RESULT_LIMIT, matches.size);
			string previous_initial = "";
			for (var i = 0; i < result_count; i++) {
				var app = matches[i];
				visible_results.add (app);
				var row = create_result_row (app);
				if (showing_all && query == "") {
					var initial = app.get_display_name ().substring (0, 1).up ();
					if (initial != previous_initial) {
						row.set_header (create_alphabet_header (initial));
						previous_initial = initial;
					}
				}
				result_list.add (row);
			}
			if (visible_results.size == 0) {
				var empty_row = new Gtk.ListBoxRow () { selectable = false, activatable = false };
				empty_row.get_style_context ().add_class ("launcher-empty");
				var empty_label = new Gtk.Label (_("No matching applications"));
				empty_label.margin = 24;
				empty_row.add (empty_label);
				result_list.add (empty_row);
			}

			result_list.show_all ();
			if (result_list.get_row_at_index (0) != null)
				result_list.select_row (result_list.get_row_at_index (0));
			if (visible)
				Idle.add (() => { position_over_anchor (); return false; });
		}

		string searchable_text (AppInfo app)
		{
			return "%s %s %s %s".printf (app.get_display_name (), app.get_name (),
				app.get_description () ?? "", app.get_executable () ?? "").down ();
		}

		int compare_results (AppInfo a, AppInfo b, string query)
		{
			if (query != "") {
				var a_name = a.get_display_name ().down ();
				var b_name = b.get_display_name ().down ();
				var a_score = fuzzy_score (a_name, query);
				var b_score = fuzzy_score (b_name, query);
				if (a_score != b_score)
					return a_score > b_score ? -1 : 1;
			} else if (!showing_all) {
				var a_count = usage_count (a);
				var b_count = usage_count (b);
				if (a_count != b_count)
					return a_count > b_count ? -1 : 1;
			}
			return a.get_display_name ().collate (b.get_display_name ());
		}

		string usage_path ()
		{
			return controller.config_folder.get_child ("launcher-usage.ini").get_path ();
		}

		void load_usage ()
		{
			var keyfile = new KeyFile ();
			try {
				keyfile.load_from_file (usage_path (), KeyFileFlags.NONE);
				foreach (var key in keyfile.get_keys ("Usage"))
					usage_counts[key] = keyfile.get_integer ("Usage", key);
			} catch (Error e) {
				// The file does not exist until the first application is recorded.
			}
		}

		void save_usage ()
		{
			var keyfile = new KeyFile ();
			foreach (var entry in usage_counts.entries)
				keyfile.set_integer ("Usage", entry.key, entry.value);
			try {
				FileUtils.set_contents (usage_path (), keyfile.to_data ());
			} catch (FileError e) {
				warning ("Unable to save launcher usage: %s", e.message);
			}
		}

		void track_active_application (Bamf.Application? old_app, Bamf.Application? new_app)
		{
			if (new_app == null)
				return;
			unowned string? desktop_file = new_app.get_desktop_file ();
			if (desktop_file == null || desktop_file == "")
				return;
			var desktop_id = Path.get_basename (desktop_file);
			foreach (var app in applications) {
				var id = app.get_id () ?? app.get_name ();
				if (id != desktop_id)
					continue;
				usage_counts[id] = usage_count (app) + 1;
				save_usage ();
				if (visible && !showing_all && search_entry.text == "")
					refresh_results ();
				break;
			}
		}

		int usage_count (AppInfo app)
		{
			var id = app.get_id () ?? app.get_name ();
			return usage_counts.has_key (id) ? usage_counts[id] : 0;
		}

		int fuzzy_score (string text, string query)
		{
			if (query == "")
				return 0;
			if (text.has_prefix (query))
				return 1000 - text.length;
			var exact = text.index_of (query);
			if (exact >= 0)
				return 800 - exact;

			var query_index = 0;
			var first_match = -1;
			var previous_match = -2;
			var consecutive = 0;
			for (var i = 0; i < text.length && query_index < query.length; i++) {
				if (text[i] != query[query_index])
					continue;
				if (first_match < 0)
					first_match = i;
				if (i == previous_match + 1)
					consecutive++;
				previous_match = i;
				query_index++;
			}
			if (query_index < query.length)
				return -1;
			return 400 + consecutive * 10 - first_match - (previous_match - first_match);
		}

		Gtk.ListBoxRow create_result_row (AppInfo app)
		{
			var row = new Gtk.ListBoxRow ();
			row.get_style_context ().add_class ("launcher-result");
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 11);
			box.margin_left = box.margin_right = 12;
			box.margin_top = box.margin_bottom = 6;
			Gtk.Image icon;
			if (app.get_icon () != null)
				icon = new Gtk.Image.from_gicon (app.get_icon (), Gtk.IconSize.DIALOG);
			else
				icon = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.DIALOG);
			icon.pixel_size = 30;
			box.pack_start (icon, false, false, 0);

			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			var title = new Gtk.Label (app.get_display_name ()) { xalign = 0.0f };
			title.ellipsize = Pango.EllipsizeMode.END;
			title.max_width_chars = 34;
			labels.pack_start (title, false, false, 0);
			var description = new Gtk.Label (app.get_description () ?? app.get_executable ()) { xalign = 0.0f };
			description.ellipsize = Pango.EllipsizeMode.END;
			description.max_width_chars = 34;
			description.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (description, false, false, 0);
			box.pack_start (labels, true, true, 0);
			var enter_hint = new Gtk.Label ("↵");
			enter_hint.get_style_context ().add_class ("launcher-enter");
			box.pack_end (enter_hint, false, false, 0);
			row.add (box);
			return row;
		}

		void show_application_context_menu (AppInfo app, Gdk.EventButton event)
		{
			if (uninstall_detection != null)
				uninstall_detection.cancel ();
			uninstall_detection = new Cancellable ();
			var detection = uninstall_detection;
			var root_x = event.x_root;
			var root_y = event.y_root;
			if (application_context != null)
				application_context.destroy ();
			var context = new Gtk.Window (Gtk.WindowType.TOPLEVEL);
			application_context = context;
			context.decorated = false;
			context.resizable = false;
			context.skip_taskbar_hint = true;
			context.skip_pager_hint = true;
			context.set_keep_above (true);
			context.transient_for = this;
			context.type_hint = Gdk.WindowTypeHint.DIALOG;
			context.get_style_context ().add_class ("launcher-app-context");

			var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
			card.margin = 8;
			context.add (card);
			var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			header.get_style_context ().add_class ("app-context-header");
			Gtk.Image app_icon;
			if (app.get_icon () != null)
				app_icon = new Gtk.Image.from_gicon (app.get_icon (), Gtk.IconSize.DIALOG);
			else
				app_icon = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.DIALOG);
			app_icon.pixel_size = 32;
			header.pack_start (app_icon, false, false, 0);
			var heading = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			var name = new Gtk.Label (app.get_display_name ()) { xalign = 0.0f };
			name.get_style_context ().add_class ("app-context-title");
			heading.pack_start (name, false, false, 0);
			var origin = new Gtk.Label (_("Checking installation source…")) { xalign = 0.0f };
			origin.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			heading.pack_start (origin, false, false, 0);
			header.pack_start (heading, true, true, 0);
			card.pack_start (header, false, false, 0);
			card.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 2);

			card.pack_start (context_action_button (_("Open"), "media-playback-start-symbolic", () => {
				try { app.launch (null, null); } catch (Error e) { warning ("Unable to launch app: %s", e.message); }
				context.hide ();
				hide_animated ();
			}), false, false, 0);

			var desktop = app as DesktopAppInfo;
			if (desktop != null) {
				foreach (unowned string action in desktop.list_actions ()) {
					var action_name = desktop.get_action_name (action);
					if (action_name == null || action_name == "")
						continue;
					var action_id = action;
					card.pack_start (context_action_button (action_name, "list-add-symbolic", () => {
						desktop.launch_action (action_id, null);
						context.hide ();
						hide_animated ();
					}), false, false, 0);
				}
			}

			context_menu_open = true;
			context.hide.connect (() => {
				if (uninstall_detection == detection)
					detection.cancel ();
				context_menu_open = false;
				if (visible && !context_dialog_open)
					Idle.add (() => { present (); return false; });
			});
			context.focus_out_event.connect (() => {
				if (!context_dialog_open)
					context.hide ();
				return false;
			});
			context.key_press_event.connect ((key) => {
				if (key.keyval == Gdk.Key.Escape) {
					context.hide ();
					return true;
				}
				return false;
			});
			context.show_all ();
			context.present ();
			Idle.add (() => {
				position_application_context (context, root_x, root_y);
				return false;
			});

			var desktop_filename = (app as DesktopAppInfo)?.get_filename ();
			uninstall_service.detect.begin (app.get_id () ?? "", app.get_executable () ?? "",
				desktop_filename, detection, (obj, result) => {
					var target = uninstall_service.detect.end (result);
					if (detection.is_cancelled () || application_context != context)
						return;
					origin.label = target != null
						? _("Installed via %s").printf (target.source) : _("Installed application");
					if (target != null) {
						card.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 2);
						var uninstall = context_action_button (_("Uninstall…"), "user-trash-symbolic", () => {
							context_dialog_open = true;
							context.hide ();
							confirm_uninstall (app, target);
						});
						uninstall.get_style_context ().add_class ("destructive-action");
						card.pack_start (uninstall, false, false, 0);
					}
					card.show_all ();
					position_application_context (context, root_x, root_y);
				});
		}

		void position_application_context (Gtk.Window context, double root_x, double root_y)
		{
			int width, height;
			context.get_size (out width, out height);
			var screen = context.get_screen ();
			var monitor = screen.get_monitor_at_point ((int) root_x, (int) root_y);
			var workarea = screen.get_monitor_workarea (monitor);
			var x = int.max (workarea.x + 8, int.min (workarea.x + workarea.width - width - 8, (int) root_x));
			var y = int.max (workarea.y + 8, int.min (workarea.y + workarea.height - height - 8, (int) root_y));
			context.move (x, y);
		}

		delegate void ContextAction ();

		Gtk.Button context_action_button (string label, string icon, owned ContextAction action)
		{
			var button = new Gtk.Button ();
			button.get_style_context ().add_class ("app-context-action");
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
			box.pack_start (new Gtk.Image.from_icon_name (icon, Gtk.IconSize.MENU), false, false, 0);
			box.pack_start (new Gtk.Label (label) { xalign = 0.0f }, true, true, 0);
			button.add (box);
			button.clicked.connect (() => { action (); });
			return button;
		}

		void confirm_uninstall (AppInfo app, UninstallTarget target)
		{
			context_menu_open = true;
			var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
				Gtk.MessageType.WARNING, Gtk.ButtonsType.CANCEL,
				_("Uninstall %s?").printf (app.get_display_name ()));
			dialog.format_secondary_text (_("This will remove %s using %s. Your personal data may be kept by the package manager.")
				.printf (target.package_id, target.source));
			dialog.add_button (_("Uninstall"), Gtk.ResponseType.ACCEPT);
			dialog.set_default_response (Gtk.ResponseType.CANCEL);
			dialog.response.connect ((response) => {
				dialog.destroy ();
				context_dialog_open = false;
				context_menu_open = false;
				if (response == Gtk.ResponseType.ACCEPT)
					run_uninstall (target);
				else if (visible)
					present ();
			});
			dialog.show_all ();
		}

		void run_uninstall (UninstallTarget target)
		{
			try {
				Pid pid;
				Process.spawn_async (null, target.argv, null,
					SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out pid);
				ChildWatch.add (pid, (child_pid, status) => {
					Process.close_pid (child_pid);
					index_applications ();
					if (visible)
						refresh_results ();
				});
			} catch (Error e) {
				warning ("Unable to uninstall '%s': %s", target.package_id, e.message);
			}
		}

		Gtk.Widget create_alphabet_header (string initial)
		{
			var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
			header.get_style_context ().add_class ("launcher-alpha-header");
			var label = new Gtk.Label (initial);
			label.get_style_context ().add_class ("launcher-alpha-letter");
			header.pack_start (label, false, false, 0);
			var divider = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
			divider.get_style_context ().add_class ("launcher-alpha-divider");
			header.pack_start (divider, true, true, 0);
			return header;
		}

		bool handle_key_press (Gdk.EventKey event)
		{
			switch (event.keyval) {
			case Gdk.Key.Escape:
				if (search_entry.text != "")
					search_entry.text = "";
				else
					hide_animated ();
				return true;
			case Gdk.Key.Up:
				move_selection (-1);
				return true;
			case Gdk.Key.Down:
				move_selection (1);
				return true;
			case Gdk.Key.Return:
			case Gdk.Key.KP_Enter:
				var row = result_list.get_selected_row ();
				if (row != null)
					activate_row (row);
				return true;
			default:
				return false;
			}
		}

		void move_selection (int delta)
		{
			if (visible_results.size == 0)
				return;
			var row = result_list.get_selected_row ();
			var index = row == null ? 0 : row.get_index () + delta;
			index = (index + visible_results.size) % visible_results.size;
			result_list.select_row (result_list.get_row_at_index (index));
		}

		void activate_row (Gtk.ListBoxRow row)
		{
			var index = row.get_index ();
			if (index < 0 || index >= visible_results.size)
				return;
			try {
				var app = visible_results[index];
				app.launch (null, null);
				var id = app.get_id () ?? app.get_name ();
				usage_counts[id] = usage_count (app) + 1;
				save_usage ();
			} catch (Error e) {
				warning ("Unable to launch '%s': %s", visible_results[index].get_name (), e.message);
			}
			hide_animated ();
		}

		void position_over_anchor ()
		{
			if (anchor_item == null)
				return;
			int width, height;
			get_size (out width, out height);
			var bar_rect = controller.position_manager.get_screen_background_region ();
			panel_x = bar_rect.x + (bar_rect.width - width) / 2;
			panel_y = bar_rect.y - height - PANEL_GAP;
			move (panel_x, panel_y);
		}

		void apply_theme ()
		{
			var color = controller.renderer.theme.FillStartColor;
			// Keep floating menus on the bar's RGB color.  Avoid formatting a
			// floating-point alpha here: printf follows the current locale and can
			// emit a decimal comma, which makes the entire GTK CSS invalid.
			var css = ".plank-native-launcher { background-color: transparent; }";
			css += ".plank-native-launcher .launcher-panel { background-color: rgb(%d,%d,%d); border: 1px solid rgba(255,255,255,0.10); border-radius: 12px; padding: 5px; box-shadow: none; }"
				.printf ((int) (color.red * 255), (int) (color.green * 255), (int) (color.blue * 255));
			css += ".plank-native-launcher .launcher-tabs { margin: 7px 7px 5px 7px; }";
			css += ".plank-native-launcher .launcher-navbar { min-height: 34px; margin: 6px 7px 0 7px; }";
			css += ".plank-native-launcher .launcher-power-button { color: rgba(255,255,255,0.68); background: transparent; background-image: none; border: none; border-radius: 8px; box-shadow: none; padding: 7px; }";
			css += ".plank-native-launcher .launcher-power-button:hover { color: white; background-color: rgba(255,255,255,0.09); }";
			css += ".plank-native-launcher .launcher-tabs button { color: rgba(255,255,255,0.58); background: transparent; background-image: none; border: none; border-radius: 8px; box-shadow: none; padding: 6px; }";
			css += ".plank-native-launcher .launcher-tabs button:hover { color: rgba(255,255,255,0.82); background-color: rgba(255,255,255,0.06); }";
			css += ".plank-native-launcher .launcher-tabs button:checked { color: white; background-color: rgba(255,255,255,0.13); }";
			css += ".plank-native-launcher .launcher-results-scroll { background: transparent; border: none; box-shadow: none; }";
			css += ".plank-native-launcher scrollbar { background: transparent; border: none; }";
			css += ".plank-native-launcher scrollbar slider { min-width: 4px; min-height: 28px; background-color: rgba(255,255,255,0.18); border-radius: 4px; }";
			css += ".plank-native-launcher .launcher-alpha-header { margin: 8px 12px 4px 12px; }";
			css += ".plank-native-launcher .launcher-alpha-letter { color: rgba(255,255,255,0.58); font-size: 11px; font-weight: bold; }";
			css += ".plank-native-launcher .launcher-alpha-divider { min-height: 1px; background-color: rgba(255,255,255,0.10); border: none; }";
			css += ".plank-native-launcher .launcher-panel list, .plank-native-launcher .launcher-panel row, .plank-native-launcher .launcher-search { background-color: rgb(%d,%d,%d); background-image: none; border: none; }"
				.printf ((int) (color.red * 255), (int) (color.green * 255), (int) (color.blue * 255));
			css += ".plank-native-launcher .launcher-search { padding: 7px 12px; margin: 4px 7px 7px 7px; border: 1px solid rgba(255,255,255,0.12); border-radius: 12px; }";
			css += ".plank-native-launcher entry, .plank-native-launcher entry:focus { color: white; background: transparent; background-image: none; border: none; border-radius: 0; box-shadow: none; outline: none; font-size: 14px; }";
			css += ".plank-native-launcher .launcher-search.launcher-search-focused { border-color: #73d216; box-shadow: 0 0 0 1px rgba(115,210,22,0.28); }";
			css += ".plank-native-launcher row { color: white; border-radius: 8px; margin: 1px 5px; transition: background-color 120ms ease; }";
			css += ".plank-native-launcher row:hover { background-color: rgba(255,255,255,0.07); }";
			css += ".plank-native-launcher row:selected { background-color: rgba(255,255,255,0.15); }";
			css += ".plank-native-launcher row:selected:hover { background-color: rgba(255,255,255,0.18); }";
			css += ".plank-native-launcher .launcher-enter { color: rgba(255,255,255,0.28); font-size: 16px; }";
			css += ".plank-native-launcher row:selected .launcher-enter { color: rgba(255,255,255,0.85); }";
			css += ".plank-native-launcher .launcher-empty { color: rgba(255,255,255,0.55); }";
			css += ".launcher-app-context { background-color: rgb(%d,%d,%d); border: 1px solid rgba(255,255,255,0.10); border-radius: 11px; padding: 5px; }"
				.printf ((int) (color.red * 255), (int) (color.green * 255), (int) (color.blue * 255));
			css += ".launcher-app-context .app-context-header { color: white; padding: 7px; min-width: 250px; }";
			css += ".launcher-app-context .app-context-title { font-weight: bold; font-size: 14px; }";
			css += ".launcher-app-context .app-context-action { color: white; background: transparent; background-image: none; border: none; border-radius: 8px; box-shadow: none; padding: 7px 9px; }";
			css += ".launcher-app-context .app-context-action:hover { background-color: rgba(255,255,255,0.10); }";
			css += ".launcher-app-context .destructive-action { color: #ff7b73; }";
			css += ".plank-power-menu { background-color: rgb(%d,%d,%d); border: 1px solid rgba(255,255,255,0.10); border-radius: 10px; padding: 5px; }"
				.printf ((int) (color.red * 255), (int) (color.green * 255), (int) (color.blue * 255));
			css += ".plank-power-menu menuitem { color: white; border-radius: 10px; padding: 7px 10px; margin: 2px; }";
			css += ".plank-power-menu menuitem:hover { background-color: rgba(255,255,255,0.11); }";
			if (theme_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), theme_provider);
			theme_provider = new Gtk.CssProvider ();
			try { theme_provider.load_from_data (css); } catch (Error e) { warning ("Launcher CSS: %s", e.message); }
			Gtk.StyleContext.add_provider_for_screen (get_screen (), theme_provider,
				Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
		}

		void hide_animated ()
		{
			if (!visible)
				return;
			animate_to (0.0, true);
		}

		void animate_to (double target, bool hide_when_done)
		{
			if (animation_timer_id > 0U)
				Source.remove (animation_timer_id);
			var start = opacity;
			int current_x, start_y;
			get_position (out current_x, out start_y);
			var end_y = hide_when_done ? panel_y + 7 : panel_y;
			var started = GLib.get_monotonic_time ();
			animation_timer_id = Timeout.add (16, () => {
				var progress = double.min (1.0, (GLib.get_monotonic_time () - started) / (ANIMATION_TIME * 1000.0));
				var eased = 1.0 - Math.pow (1.0 - progress, 3.0);
				opacity = start + (target - start) * eased;
				move (panel_x, (int) Math.round (start_y + (end_y - start_y) * eased));
				if (progress < 1.0)
					return true;
				animation_timer_id = 0U;
				if (hide_when_done)
				{
					hide ();
					controller.renderer.animated_draw ();
				}
				return false;
			});
		}
	}
}
