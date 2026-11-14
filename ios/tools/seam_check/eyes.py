"""Where the two eyes are in a screenshot of the puppet screen (dark iris blobs)."""
from collections import deque
from PIL import Image

HEAD = (390, 720, 810, 1000)   # around the eyes on the iPhone 16e puppet screen (pixels)


def eyes(path):
    im = Image.open(path).convert("L").crop(HEAD)
    small = im.resize((im.width // 2, im.height // 2))
    W, H = small.size
    px = small.load()
    seen = set()
    blobs = []
    for y in range(H):
        for x in range(W):
            if (x, y) in seen or px[x, y] > 80:
                continue
            q = deque([(x, y)]); seen.add((x, y)); pts = []
            while q:
                a, b = q.popleft(); pts.append((a, b))
                for n in ((a + 1, b), (a - 1, b), (a, b + 1), (a, b - 1)):
                    if 0 <= n[0] < W and 0 <= n[1] < H and n not in seen and px[n] <= 80:
                        seen.add(n); q.append(n)
            if len(pts) > 25:
                blobs.append((len(pts), sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)))
    blobs.sort(reverse=True)
    # the two eyes: the biggest pair side by side (the nose and mouth sit between, lower)
    pairs = [(a[0] + b[0], a, b) for i, a in enumerate(blobs[:8]) for b in blobs[i + 1:8]
             if 55 < abs(a[1] - b[1]) < 120 and abs(a[2] - b[2]) < 35]
    two = sorted(max(pairs)[1:], key=lambda b: b[1]) if pairs else []
    return [(HEAD[0] + 2 * b[1], HEAD[1] + 2 * b[2]) for b in two]


if __name__ == "__main__":
    import sys
    for p in sys.argv[1:]:
        print(p.split("/")[-1], [(round(x), round(y)) for x, y in eyes(p)])
