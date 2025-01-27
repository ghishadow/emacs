/* Communication module for Android terminals.  -*- c-file-style: "GNU" -*-

Copyright (C) 2023 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

package org.gnu.emacs;

import java.util.ArrayList;
import java.util.List;

import android.app.ActivityOptions;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

/* Code to paper over the differences in lifecycles between
   "activities" and windows.  There are four interfaces to an instance
   of this class:

     registerWindowConsumer (WindowConsumer)
     registerWindow (EmacsWindow)
     removeWindowConsumer (WindowConsumer)
     removeWindow (EmacsWindow)

   A WindowConsumer is expected to allow an EmacsWindow to be attached
   to it, and be created or destroyed.

   Every time a window is created, registerWindow checks the list of
   window consumers.  If a consumer exists and does not currently have
   a window of its own attached, it gets the new window.  Otherwise,
   the window attachment manager starts a new consumer.

   Every time a consumer is registered, registerWindowConsumer checks
   the list of available windows.  If a window exists and is not
   currently attached to a consumer, then the consumer gets it.

   Finally, every time a window is removed, the consumer is
   destroyed.  */

public final class EmacsWindowAttachmentManager
{
  private final static String TAG = "EmacsWindowAttachmentManager";

  /* The single window attachment manager ``object''.  */
  public static final EmacsWindowAttachmentManager MANAGER;

  static
  {
    MANAGER = new EmacsWindowAttachmentManager ();
  };

  public interface WindowConsumer
  {
    public void attachWindow (EmacsWindow window);
    public EmacsWindow getAttachedWindow ();
    public void detachWindow ();
    public void destroy ();
  };

  /* List of currently attached window consumers.  */
  public List<WindowConsumer> consumers;

  /* List of currently attached windows.  */
  public List<EmacsWindow> windows;

  public
  EmacsWindowAttachmentManager ()
  {
    consumers = new ArrayList<WindowConsumer> ();
    windows = new ArrayList<EmacsWindow> ();
  }

  public void
  registerWindowConsumer (WindowConsumer consumer)
  {
    Log.d (TAG, "registerWindowConsumer " + consumer);

    consumers.add (consumer);

    for (EmacsWindow window : windows)
      {
	if (window.getAttachedConsumer () == null)
	  {
	    Log.d (TAG, "registerWindowConsumer: attaching " + window);
	    consumer.attachWindow (window);
	    return;
	  }
      }

    Log.d (TAG, "registerWindowConsumer: sendWindowAction 0, 0");
    EmacsNative.sendWindowAction ((short) 0, 0);
  }

  public synchronized void
  registerWindow (EmacsWindow window)
  {
    Intent intent;
    ActivityOptions options;

    Log.d (TAG, "registerWindow (maybe): " + window);

    if (windows.contains (window))
      /* The window is already registered.  */
      return;

    Log.d (TAG, "registerWindow: " + window);

    windows.add (window);

    for (WindowConsumer consumer : consumers)
      {
	if (consumer.getAttachedWindow () == null)
	  {
	    Log.d (TAG, "registerWindow: attaching " + consumer);
	    consumer.attachWindow (window);
	    return;
	  }
      }

    intent = new Intent (EmacsService.SERVICE,
			 EmacsMultitaskActivity.class);
    intent.addFlags (Intent.FLAG_ACTIVITY_NEW_DOCUMENT
		     | Intent.FLAG_ACTIVITY_NEW_TASK
		     | Intent.FLAG_ACTIVITY_MULTIPLE_TASK);

    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N)
      EmacsService.SERVICE.startActivity (intent);
    else
      {
	/* Specify the desired window size.  */
	options = ActivityOptions.makeBasic ();
	options.setLaunchBounds (window.getGeometry ());
	EmacsService.SERVICE.startActivity (intent,
					    options.toBundle ());
      }

    Log.d (TAG, "registerWindow: startActivity");
  }

  public void
  removeWindowConsumer (WindowConsumer consumer, boolean isFinishing)
  {
    EmacsWindow window;

    Log.d (TAG, "removeWindowConsumer " + consumer);

    window = consumer.getAttachedWindow ();

    if (window != null)
      {
	Log.d (TAG, "removeWindowConsumer: detaching " + window);

	consumer.detachWindow ();
	window.onActivityDetached (isFinishing);
      }

    Log.d (TAG, "removeWindowConsumer: removing " + consumer);
    consumers.remove (consumer);
  }

  public synchronized void
  detachWindow (EmacsWindow window)
  {
    WindowConsumer consumer;

    Log.d (TAG, "detachWindow " + window);

    if (window.getAttachedConsumer () != null)
      {
	consumer = window.getAttachedConsumer ();

	Log.d (TAG, "detachWindow: removing" + consumer);

	consumers.remove (consumer);
	consumer.destroy ();
      }

    windows.remove (window);
  }

  public void
  noticeIconified (WindowConsumer consumer)
  {
    EmacsWindow window;

    Log.d (TAG, "noticeIconified " + consumer);

    /* If a window is attached, send the appropriate iconification
       events.  */
    window = consumer.getAttachedWindow ();

    if (window != null)
      window.noticeIconified ();
  }

  public void
  noticeDeiconified (WindowConsumer consumer)
  {
    EmacsWindow window;

    Log.d (TAG, "noticeDeiconified " + consumer);

    /* If a window is attached, send the appropriate iconification
       events.  */
    window = consumer.getAttachedWindow ();

    if (window != null)
      window.noticeDeiconified ();
  }

  public synchronized List<EmacsWindow>
  copyWindows ()
  {
    return new ArrayList<EmacsWindow> (windows);
  }
};
