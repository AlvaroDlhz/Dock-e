//
// The applications the launcher offers, and how they are ordered and found.
//

namespace Plank
{
	/**
	 * Knows the installed applications which can be opened, without any
	 * notion of how they are shown.
	 */
	public class LauncherCatalog : Object
	{
		/**
		 * Every application, ordered by its initial and then by its name.
		 */
		public Gee.ArrayList<AppInfo> applications { get; private set; }

		LauncherUsage usage;
		// What is compared with the typed text, per application
		Gee.HashMap<AppInfo, string> search_names;
		Gee.HashMap<AppInfo, string> search_texts;

		public LauncherCatalog (LauncherUsage usage)
		{
			this.usage = usage;
			applications = new Gee.ArrayList<AppInfo> ();
			search_names = new Gee.HashMap<AppInfo, string> ();
			search_texts = new Gee.HashMap<AppInfo, string> ();
		}

		/**
		 * Reads the installed applications anew.
		 */
		public void index ()
		{
			applications.clear ();
			search_names.clear ();
			search_texts.clear ();
			var seen = new Gee.HashSet<string> ();
			foreach (unowned AppInfo app in AppInfo.get_all ()) {
				var id = usage_id (app);
				if (!app.should_show () || !is_available (app) || id in seen)
					continue;
				seen.add (id);
				applications.add (app);
				search_names[app] = LauncherSearch.normalize (app.get_display_name ());
				// The initials find "Visual Studio Code" when "vsc" is typed
				search_texts[app] = LauncherSearch.normalize ("%s %s %s".printf (app.get_name (),
					app.get_description () ?? "", app.get_executable () ?? ""));
			}
			applications.sort ((a, b) => {
				var initial_order = alphabet_initial (a).collate (alphabet_initial (b));
				if (initial_order != 0)
					return initial_order;
				return a.get_display_name ().collate (b.get_display_name ());
			});
		}

		/**
		 * The applications opened most, the most used one first.
		 *
		 * @param limit how many of them there are at most
		 */
		public Gee.ArrayList<AppInfo> frequent (int limit)
		{
			var result = new Gee.ArrayList<AppInfo> ();
			var usage_scores = new Gee.HashMap<AppInfo, double?> ();
			foreach (var app in applications) {
				var usage_score = usage.score (usage_id (app));
				if (usage_score <= 0.0)
					continue;
				usage_scores[app] = usage_score;
				result.add (app);
			}
			result.sort ((a, b) => {
				if (usage_scores[a] != usage_scores[b])
					return usage_scores[a] > usage_scores[b] ? -1 : 1;
				return a.get_display_name ().collate (b.get_display_name ());
			});
			while (result.size > limit)
				result.remove_at (result.size - 1);
			return result;
		}

		/**
		 * The applications matching a typed text, the best match first.
		 *
		 * @param query the typed text, normalized
		 */
		public Gee.ArrayList<AppInfo> search (string query)
		{
			var matches = new Gee.ArrayList<AppInfo> ();
			var scores = new Gee.HashMap<AppInfo, int> ();
			foreach (var app in applications) {
				var match = match_score (app, query);
				if (match < 0)
					continue;
				scores[app] = match;
				matches.add (app);
			}
			matches.sort ((a, b) => {
				if (scores[a] != scores[b])
					return scores[a] > scores[b] ? -1 : 1;
				return a.get_display_name ().collate (b.get_display_name ());
			});
			return matches;
		}

		/**
		 * Rates how well an application matches the typed text, preferring
		 * its name over its description and the ones opened more often.
		 *
		 * @return a higher number for a better match, negative for none at all
		 */
		public int match_score (AppInfo app, string query)
		{
			var habit = (int) (double.min (10.0, usage.score (usage_id (app))) * 30.0);
			var name = LauncherSearch.score (search_names[app], query);
			if (name >= 0)
				return 1000 + name + habit;
			// Descriptions are long, a loose match in them means little
			var text = LauncherSearch.score (search_texts[app], query);
			if (text >= 800)
				return text / 2 + habit;
			return -1;
		}

		/**
		 * What the usage history knows an application by.
		 */
		public static string usage_id (AppInfo app)
		{
			return app.get_id () ?? app.get_name ();
		}

		/**
		 * The letter an application is filed under.
		 */
		public static string alphabet_initial (AppInfo app)
		{
			return initial_of (app.get_display_name ());
		}

		/**
		 * The letter a name is filed under, without its accent. Names which
		 * do not start with a letter share "#".
		 */
		public static string initial_of (string display_name)
		{
			var name = display_name.strip ();
			if (name == "")
				return "#";
			var decomposed = name.normalize (-1, GLib.NormalizeMode.NFD);
			var initial = decomposed.get_char ();
			if (!initial.isalpha ())
				return "#";
			return initial.to_string ().up ();
		}

		/**
		 * Whether the program of an application is really there. Desktop
		 * files outlive the removal of what they start.
		 */
		public static bool is_available (AppInfo app)
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
	}
}
