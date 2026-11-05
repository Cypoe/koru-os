/* kvview — vendored webview shim: webkit2gtk-4.1 window, url as argv[1].
 * On load-finished it evaluates document.title and prints the KVVIEW
 * line — the gate's evidence that a real engine fetched, rendered, and
 * ran JS, not just that a window opened. */
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

static void on_js(GObject *o, GAsyncResult *r, gpointer d) {
    (void)d;
    JSCValue *v = webkit_web_view_evaluate_javascript_finish(
        WEBKIT_WEB_VIEW(o), r, NULL);
    const char *t = v ? jsc_value_to_string(v) : "(none)";
    printf("KVVIEW loaded title=\"%s\" uri=\"%s\"\n",
           t, webkit_web_view_get_uri(WEBKIT_WEB_VIEW(o)));
    fflush(stdout);
}

static void on_load(WebKitWebView *wv, WebKitLoadEvent ev, gpointer d) {
    (void)d;
    if (ev == WEBKIT_LOAD_FINISHED)
        webkit_web_view_evaluate_javascript(wv, "document.title", -1,
            NULL, NULL, NULL, on_js, NULL);
}

int main(int argc, char **argv) {
    const char *url = argc > 1 ? argv[1] : "about:blank";
    gtk_init(&argc, &argv);
    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(win), 900, 700);
    gtk_window_set_title(GTK_WINDOW(win), "koru webview");
    WebKitWebView *wv = WEBKIT_WEB_VIEW(webkit_web_view_new());
    gtk_container_add(GTK_CONTAINER(win), GTK_WIDGET(wv));
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    g_signal_connect(wv, "load-changed", G_CALLBACK(on_load), NULL);
    webkit_web_view_load_uri(wv, url);
    gtk_widget_show_all(win);
    gtk_main();
    return 0;
}
