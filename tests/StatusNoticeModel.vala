//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;

namespace PlankTests
{
	public static void register_status_notice_model_tests ()
	{
		Test.add_func ("/Services/StatusNoticeModel/show", status_notice_model_show);
		Test.add_func ("/Services/StatusNoticeModel/replace", status_notice_model_replace);
		Test.add_func ("/Services/StatusNoticeModel/dismiss", status_notice_model_dismiss);
		Test.add_func ("/Services/StatusNoticeModel/ignore-empty", status_notice_model_ignore_empty);
	}

	void status_notice_model_show ()
	{
		var model = new StatusNoticeModel ();
		var changes = 0;
		model.changed.connect (() => changes++);
		model.show_error ("  Connection failed  ");
		assert (model.visible && model.message == "Connection failed");
		assert (changes == 1);
	}

	void status_notice_model_replace ()
	{
		var model = new StatusNoticeModel ();
		var changes = 0;
		model.changed.connect (() => changes++);
		model.show_error ("First error");
		model.show_error ("Second error");
		assert (model.visible && model.message == "Second error");
		assert (changes == 2);
	}

	void status_notice_model_dismiss ()
	{
		var model = new StatusNoticeModel ();
		model.show_error ("Error");
		model.dismiss ();
		assert (!model.visible && model.message == "");
	}

	void status_notice_model_ignore_empty ()
	{
		var model = new StatusNoticeModel ();
		var changes = 0;
		model.changed.connect (() => changes++);
		model.show_error ("  ");
		model.dismiss ();
		assert (!model.visible && model.message == "" && changes == 0);
	}
}
