/* Sprinter-only reimplementation of asm/overlay/board/helpers.asm's four
 * scalar helpers (S5 substep 3b, RULES(0)/BOARD(1) port).
 *
 * helpers.asm documents its own stack layout as "SDCC/IY packed uint8 args:
 * a@sp+2, b@sp+3" (helpers.asm:9,82) -- one stack byte per uint8_t argument.
 * That is the ZX/Next SDCC -clib=sdcc_iy convention. Sprinter's whole C
 * build uses z88dk's classic compiler (-clib=default, the only option for
 * +pps), which promotes every scalar argument to a full 16-bit stack slot
 * regardless of C type (overlay_loader_sprinter.asm's own file banner
 * documents this exact mismatch -- it is what caused the first MAME boot
 * crash, S5 subshag 2). Hand-porting helpers.asm's SP+2/SP+3 arithmetic to
 * the classic layout would mean verifying a second stack ABI by hand; these
 * four functions are trivial, so instead they are written as ordinary
 * portable C with the exact signatures src/spectrum/overlay/board_apply_ovl.c
 * already declares (board_apply_ovl.c:34-37) and calls with normal C
 * linkage -- the same zero-special-ABI path control_ovl.c's own functions
 * already proved for the overlay entry points themselves.
 *
 * src/spectrum/overlay/board_apply_ovl.c itself is untouched and still
 * links against helpers.asm on ZX/Next -- this file is Sprinter-only,
 * linked in board_apply_ovl.c's place for that one translation unit.
 */

#include <stdint.h>

uint8_t abs_delta(uint8_t a, uint8_t b)
{
    return a >= b ? (uint8_t)(a - b) : (uint8_t)(b - a);
}

uint8_t piece_side(char piece)
{
    return (piece >= 'a' && piece <= 'z') ? 1u : 0u;
}

int8_t rules_piece_from_char(char piece)
{
    switch (piece) {
    case 'P': return 1;
    case 'N': return 2;
    case 'B': return 3;
    case 'R': return 4;
    case 'Q': return 5;
    case 'K': return 6;
    case 'p': return -1;
    case 'n': return -2;
    case 'b': return -3;
    case 'r': return -4;
    case 'q': return -5;
    case 'k': return -6;
    default: return 0;
    }
}

char promotion_piece(char pawn, char promo)
{
    char p = promo ? promo : 'q';

    if (pawn >= 'A' && pawn <= 'Z') {
        if (p >= 'a' && p <= 'z') {
            p = (char)(p - ('a' - 'A'));
        }
    } else {
        if (p >= 'A' && p <= 'Z') {
            p = (char)(p + ('a' - 'A'));
        }
    }
    return p;
}
