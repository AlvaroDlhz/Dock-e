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
	public class StatusNoticeModel : Object
	{
		public bool visible { get; private set; default = false; }
		public string message { get; private set; default = ""; }

		public signal void changed ();

		public void show_error (string message)
		{
			var normalized = message.strip ();
			if (normalized == "")
				return;
			this.message = normalized;
			visible = true;
			changed ();
		}

		public void dismiss ()
		{
			if (!visible && message == "")
				return;
			visible = false;
			message = "";
			changed ();
		}
	}
}
