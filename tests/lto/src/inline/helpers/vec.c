struct vec { double x, y, z; };
double dot(const struct vec *a, const struct vec *b) { return a->x * b->x + a->y * b->y + a->z * b->z; }
void scale(struct vec *v, double k) { v->x *= k; v->y *= k; v->z *= k; }
void add(struct vec *r, const struct vec *a, const struct vec *b) { r->x = a->x + b->x; r->y = a->y + b->y; r->z = a->z + b->z; }
