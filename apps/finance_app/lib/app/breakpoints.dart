/// Width classes used for layout decisions instead of operating system checks.
enum WindowClass { compact, medium, expanded }

const double mediumBreakpoint = 600;
const double expandedBreakpoint = 1024;

WindowClass windowClassFor(double width) {
  if (width < mediumBreakpoint) return WindowClass.compact;
  if (width < expandedBreakpoint) return WindowClass.medium;
  return WindowClass.expanded;
}
