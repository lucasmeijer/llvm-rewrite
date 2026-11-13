struct point { int x, y; };
int manhattan(struct point a, struct point b) {
  int dx = a.x - b.x, dy = a.y - b.y;
  return (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);
}
