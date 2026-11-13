// sentry-native's shutdown. libghostty links Sentry in statically, and
// GhosttyKit's headers do not declare it.
int sentry_close(void);
