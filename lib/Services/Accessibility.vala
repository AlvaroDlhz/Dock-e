//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

namespace Plank
{
	public class Accessibility : Object
	{
		public const string KEYBOARD_NAVIGATION_CLASS = "keyboard-navigation";

		public static void describe (Gtk.Widget widget, string name, string? description = null)
		{
			var accessible = widget.get_accessible ();
			accessible.set_name (name);
			if (description != null && description.strip () != "")
				accessible.set_description (description);
		}

		public static void set_role (Gtk.Widget widget, Atk.Role role)
		{
			widget.get_accessible ().set_role (role);
		}

		public static void set_keyboard_navigation (Gtk.Widget widget, bool enabled)
		{
			var context = widget.get_style_context ();
			if (enabled)
				context.add_class (KEYBOARD_NAVIGATION_CLASS);
			else
				context.remove_class (KEYBOARD_NAVIGATION_CLASS);
		}
	}
}
