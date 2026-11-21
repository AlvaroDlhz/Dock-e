//
// The commands the launcher offers after a slash, beyond its own.
//

namespace Plank
{
	/**
	 * Something the launcher does when it is asked to by name.
	 */
	public class LauncherCommand : Object
	{
		/**
		 * What tells it apart from every other command.
		 */
		public string id { get; construct; }
		/**
		 * What it is called in the list.
		 */
		public string name { get; construct; }
		public string icon { get; construct; }
		/**
		 * What can be typed after the slash to find it.
		 */
		public string[] words { get; construct; }
		/**
		 * What it runs, or what it is about.
		 */
		public string argument { get; construct; }

		public LauncherCommand (string id, string name, string icon, string[] words, string argument)
		{
			Object (id: id, name: name, icon: icon, words: words, argument: argument);
		}

		/**
		 * What the typed text is compared with.
		 */
		public string search_text ()
		{
			return LauncherSearch.normalize ("%s %s".printf (string.joinv (" ", words), name));
		}

		/**
		 * How it is typed, for the line below its name.
		 */
		public string hint ()
		{
			string[] typed = {};
			foreach (unowned string word in words)
				typed += "/" + word;
			return string.joinv (" · ", typed);
		}
	}

	/**
	 * The commands of the user, read from a file in the folder of the dock:
	 *
	 * {{{
	 * [vpn]
	 * Name=Connect to the VPN
	 * Aliases=tunnel;work
	 * Icon=network-vpn-symbolic
	 * Exec=nmcli connection up office
	 * }}}
	 *
	 * The name of a group is what is typed after the slash. Only Exec is
	 * required. The file is read once and again whenever it is saved.
	 */
	public class LauncherCommands : Object
	{
		public const string FILE_NAME = "commands.ini";
		public const string ID_PREFIX = "custom:";

		const string DEFAULT_ICON = "system-run-symbolic";
		// An editor writes a file in several steps
		const uint RELOAD_DELAY = 150U;

		public Gee.ArrayList<LauncherCommand> commands { get; private set; }

		File? file;
		FileMonitor? monitor;
		uint reload_timer_id = 0U;

		/**
		 * @param file where the commands are written, null for none at all
		 */
		public LauncherCommands (File? file)
		{
			this.file = file;
			commands = new Gee.ArrayList<LauncherCommand> ();
			if (file == null)
				return;
			try {
				monitor = file.monitor_file (FileMonitorFlags.NONE);
				monitor.changed.connect (schedule_reload);
			} catch (Error e) {
				warning ("Changes to '%s' will not be noticed: %s", file.get_path (), e.message);
			}
			load ();
		}

		~LauncherCommands ()
		{
			if (reload_timer_id > 0U)
				Source.remove (reload_timer_id);
			if (monitor != null)
				monitor.changed.disconnect (schedule_reload);
		}

		void schedule_reload ()
		{
			if (reload_timer_id > 0U)
				Source.remove (reload_timer_id);
			reload_timer_id = Timeout.add (RELOAD_DELAY, () => {
				reload_timer_id = 0U;
				load ();
				return false;
			});
		}

		void load ()
		{
			commands.clear ();
			string data;
			try {
				FileUtils.get_contents (file.get_path (), out data);
			} catch (FileError e) {
				// Having no commands of one's own is the usual case
				if (!(e is FileError.NOENT))
					warning ("Unable to read '%s': %s", file.get_path (), e.message);
				return;
			}
			var problems = new Gee.ArrayList<string> ();
			commands = parse (data, problems);
			foreach (var problem in problems)
				warning ("%s: %s", file.get_path (), problem);
			debug ("Loaded %d launcher command(s) from '%s'", commands.size, file.get_path ());
		}

		/**
		 * Reads commands as they are written in the file.
		 *
		 * @param data the contents of the file
		 * @param problems is told about every command which had to be left out
		 */
		public static Gee.ArrayList<LauncherCommand> parse (string data, Gee.List<string>? problems = null)
		{
			var result = new Gee.ArrayList<LauncherCommand> ();
			var keys = new KeyFile ();
			try {
				keys.load_from_data (data, -1, KeyFileFlags.NONE);
			} catch (Error e) {
				if (problems != null)
					problems.add (e.message);
				return result;
			}

			foreach (unowned string group in keys.get_groups ()) {
				var word = LauncherSearch.normalize (group.strip ());
				if (word == "" || word.contains (" ") || word.contains ("/")) {
					if (problems != null)
						problems.add ("[%s] is not one word, which is what is typed after the slash".printf (group));
					continue;
				}

				var exec = read (keys, group, "Exec");
				try {
					string[] arguments;
					if (exec == "" || !Shell.parse_argv (exec, out arguments))
						throw new ShellError.EMPTY_STRING ("nothing to run");
				} catch (ShellError e) {
					if (problems != null)
						problems.add ("[%s] has no Exec which can be run: %s".printf (group, e.message));
					continue;
				}

				string[] words = { word };
				try {
					if (keys.has_key (group, "Aliases")) {
						foreach (unowned string alias in keys.get_string_list (group, "Aliases")) {
							var normalized = LauncherSearch.normalize (alias.strip ());
							if (normalized != "" && !(normalized in words))
								words += normalized;
						}
					}
				} catch (KeyFileError e) {
					// The command is still good without its other names
				}

				var name = read (keys, group, "Name");
				var icon = read (keys, group, "Icon");
				result.add (new LauncherCommand (ID_PREFIX + word, name != "" ? name : group.strip (),
					icon != "" ? icon : DEFAULT_ICON, words, exec));
			}
			return result;
		}

		static string read (KeyFile keys, string group, string key)
		{
			try {
				// Names may be translated the way desktop files are
				return keys.get_locale_string (group, key, null).strip ();
			} catch (KeyFileError e) {
				return "";
			}
		}
	}
}
