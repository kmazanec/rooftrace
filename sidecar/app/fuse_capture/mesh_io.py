"""Wavefront OBJ vertex parsing for the iOS capture fusion stage (ADR-007).

The ARKit world mesh is uploaded as an OBJ. ICP only needs the vertex positions,
so this parser extracts the ``v x y z`` lines into an (N, 3) float64 array and
ignores everything else (faces, normals, texcoords, comments).

Security: the parser is purely line-by-line string handling — no ``eval``, no
object construction from the file. A vertex-count cap bounds memory so a hostile
or accidental multi-million-vertex mesh can't exhaust the process. Malformed
vertex lines are skipped rather than raising, so a partially-corrupt mesh
degrades to the vertices it can read.
"""

from __future__ import annotations

import numpy as np
import numpy.typing as npt

# A residential ARKit walk-around mesh is well under this. The cap is the same
# order as the plane-fit point-array guard; a mesh past it is rejected.
MAX_VERTICES = 5_000_000


class MeshTooLargeError(ValueError):
    """Raised when an OBJ declares more vertices than ``MAX_VERTICES``."""


def parse_obj(data: bytes) -> npt.NDArray[np.float64]:
    """Parse OBJ bytes into an (N, 3) float64 vertex array.

    Returns an empty (0, 3) array when the input contains no vertex lines.
    Raises :class:`MeshTooLargeError` if more than ``MAX_VERTICES`` vertices are
    present (checked incrementally so we never build an oversized buffer first).
    """
    text = data.decode("utf-8", errors="ignore")

    xs: list[float] = []
    ys: list[float] = []
    zs: list[float] = []

    for line in text.splitlines():
        # Fast reject: only "v " vertex lines matter (NOT "vn"/"vt"/"vp").
        if not line.startswith("v "):
            continue
        parts = line.split()
        # parts[0] == "v"; need at least x, y, z.
        if len(parts) < 4:
            continue
        try:
            x = float(parts[1])
            y = float(parts[2])
            z = float(parts[3])
        except ValueError:
            # Skip a malformed vertex line rather than failing the whole mesh.
            continue

        xs.append(x)
        ys.append(y)
        zs.append(z)
        if len(xs) > MAX_VERTICES:
            raise MeshTooLargeError(
                f"OBJ exceeds the maximum of {MAX_VERTICES} vertices"
            )

    if not xs:
        return np.empty((0, 3), dtype=np.float64)

    return np.column_stack(
        (
            np.asarray(xs, dtype=np.float64),
            np.asarray(ys, dtype=np.float64),
            np.asarray(zs, dtype=np.float64),
        )
    )
