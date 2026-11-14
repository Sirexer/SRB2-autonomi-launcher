#include "my_application.h"

int main(int argc, char** argv) {
  // One launcher at a time: two would fight over the antd port and the same
  // settings and caches. "--new-instance" opens another one anyway.
  gboolean single_instance = TRUE;
  for (int i = 1; i < argc; i++) {
    if (g_strcmp0(argv[i], "--new-instance") == 0) single_instance = FALSE;
  }
  g_autoptr(MyApplication) app = my_application_new(single_instance);
  return g_application_run(G_APPLICATION(app), argc, argv);
}
