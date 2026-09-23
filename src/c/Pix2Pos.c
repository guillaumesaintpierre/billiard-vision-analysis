// Pix2Pos.c — Projet Billard 2025
// Louis Gosset, Joseph Belamich, Guillaume Saint-Pierre
// ------------------------------------------------------------
// But du programme :
// 1) Lire une image binaire (pixmap.bin) contenant des pixels en 0x00RRGGBB
// 2) Construire 3 masques (rouge, jaune, blanc) selon des seuils RGB
// 3) Chercher, pour chaque masque, le carré BallSize x BallSize qui contient
//    le plus de pixels “compatibles” (=> meilleure position de la boule)
// 4) Écrire un fichier pos.txt au format imposé:
//
//     Red:    x, y, score
//     Yellow: x, y, score
//     White:  x, y, score
//
// Convention importante :
// - Si une boule n’est pas détectée : on écrit -1, -1, 0
//
// Gestion des erreurs pour LabVIEW :
// - stderr : ERROR(<code>): message (format stable)
// - exit code : 0 si OK ; sinon un code POSITIF “stable”
// ------------------------------------------------------------

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define BALL_MIN_SCORE 15   // score minimum pour accepter une détection comme “boule trouvée”

// Bornes “raisonnables” pour éviter de lire des fichiers corrompus / pas au bon format
#define WIDTH_MIN   100
#define WIDTH_MAX   1000
#define HEIGHT_MIN  100
#define HEIGHT_MAX  1000

// Contraintes projet: taille du carré de recherche (diamètre estimé de la boule)
#define BALLSIZE_MIN 10
#define BALLSIZE_MAX 15

#define INPUT_FILENAME  "pixmap.bin"
#define OUTPUT_FILENAME "pos.txt"

// ------------------------------------------------------------
// Codes d'erreur internes (NÉGATIFS)
// Le but est d’avoir des codes précis et stables pour debug LabVIEW.
// ------------------------------------------------------------
enum {
    ERR_BAD_ARGC            = -1,

    ERR_OPEN_INPUT          = -2,
    ERR_FSEEK_END           = -3,
    ERR_FTELL               = -4,
    ERR_FSEEK_SET           = -5,
    ERR_FILE_TOO_SMALL      = -6,
    ERR_READ_HEADER         = -7,
    ERR_DIM_OUT_OF_RANGE    = -8,
    ERR_NOT_ENOUGH_PIXELS   = -9,
    ERR_ALLOC_PIXELS        = -10,
    ERR_READ_PIXELS         = -11,

    ERR_PARSE_LMIN          = -12,
    ERR_PARSE_LMAX          = -13,
    ERR_PARSE_CMIN          = -14,
    ERR_PARSE_CMAX          = -15,

    // Couleurs: 4 couleurs * 6 paramètres = 24 codes => -16 .. -39
    ERR_PARSE_COLOR_BASE    = -16,

    ERR_PARSE_BALLSIZE      = -40,
    ERR_BALLSIZE_RANGE      = -41,

    ERR_IMAGE_BOUNDS        = -42,
    ERR_RECT_INVALID        = -43,

    ERR_ALLOC_MASKS         = -44,
    ERR_ALLOC_INTEGRAL      = -45,

    ERR_OPEN_OUTPUT         = -46
};

// ------------------------------------------------------------
// Utils : messages stderr + gestion “stable” des codes
// ------------------------------------------------------------

static int fail(int code, const char *fmt, ...)
{
    // fail() = “je renvoie une erreur” + j’imprime un message standardisé.
    // Format stable important pour que LabVIEW puisse parser/afficher correctement.
    va_list ap;
    fprintf(stderr, "ERROR(%d): ", code);

    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);

    fprintf(stderr, "\n");
    return code; // on renvoie le code interne (négatif)
}

static void warn_msg(const char *fmt, ...)
{
    // Warning = on avertit mais on ne plante pas, exit code restera 0.
    va_list ap;
    fprintf(stderr, "WARNING: ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
}

// Conversion "rc interne" -> exit code système stable
static int rc_to_exit_code(int rc)
{
    // IMPORTANT :
    // - Sur beaucoup de systèmes, un return négatif devient un code “mod 256”
    //   (ex: -8 => 248), ce qui est nul pour LabVIEW.
    // - Ici on impose : 0 si OK, sinon valeur POSITIVE du code interne.
    if (rc == 0) return 0;
    if (rc < 0) rc = -rc;

    // Optionnel : on borne à 255 si tu veux être ultra-compatible
    // (exit codes classiques = 0..255)
    if (rc > 255) rc = 255;
    return rc;
}

// swap 32 bits : utile si le fichier et la machine n'ont pas la même endianness
static inline uint32_t swap32(uint32_t v)
{
    return ((v & 0x000000FFu) << 24) |
            ((v & 0x0000FF00u) << 8)  |
            ((v & 0x00FF0000u) >> 8)  |
            ((v & 0xFF000000u) >> 24);
}

// Extraction composantes depuis un pixel 0x00RRGGBB
static inline int getR(uint32_t p) { return (int)((p >> 16) & 0xFF); }
static inline int getG(uint32_t p) { return (int)((p >> 8)  & 0xFF); }
static inline int getB(uint32_t p) { return (int)( p        & 0xFF); }

// ------------------------------------------------------------
// Structures de données “propres” (plus lisible que 40 variables séparées)
// ------------------------------------------------------------

typedef struct {
    int rmin, rmax;
    int gmin, gmax;
    int bmin, bmax;
} ColorRange;

typedef struct {
    int Lmin, Lmax;
    int Cmin, Cmax;   // L = lignes = y, C = colonnes = x
} BillardRect;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t *pix;    // tableau width*height en 0x00RRGGBB
} Pixmap;

// ------------------------------------------------------------
// Parsing paramètres (robuste : vérifie bien que toute la chaîne est un entier)
// ------------------------------------------------------------

static long parse_long(const char *s, bool *ok)
{
    errno = 0;
    char *end = NULL;
    long v = strtol(s, &end, 10);

    // Conditions d’échec:
    // - errno != 0 (overflow, etc.)
    // - end == s (rien parsé)
    // - *end != '\0' (reste des caractères non numériques)
    if (errno != 0 || end == s || *end != '\0') {
        *ok = false;
        return 0;
    }
    *ok = true;
    return v;
}

static void usage(void)
{
    // Ici on ne fait pas un usage “beau”, mais un message clair côté stderr.
    fprintf(stderr,
            "ERROR: Pas le bon nombre de paramètres.\n"
            "Attendu 29 paramètres:\n"
            " Lmin Lmax Cmin Cmax\n"
            " Rrmin Rrmax Rgmin Rgmax Rbmin Rbmax\n"
            " Yrmin Yrmax Ygmin Ygmax Ybmin Ybmax\n"
            " Wrmin Wrmax Wgmin Wgmax Wbmin Wbmax\n"
            " Brmin Brmax Bgmin Bgmax Bbmin Bbmax\n"
            " BallSize\n");
}

// ------------------------------------------------------------
// Lecture du pixmap
// - lit w,h (uint32)
// - détecte endianness (swap si nécessaire)
// - accepte un fichier avec “trop de pixels” (on ignore le surplus)
// - refuse un fichier avec “pas assez de pixels”
// ------------------------------------------------------------
static int read_pixmap(Pixmap *pm_out)
{
    *pm_out = (Pixmap){0, 0, NULL};

    FILE *fp = fopen(INPUT_FILENAME, "rb");
    if (!fp) {
        return fail(ERR_OPEN_INPUT, "Impossible d'ouvrir '%s': %s",
                    INPUT_FILENAME, strerror(errno));
    }

    // On calcule la taille du fichier pour vérifier qu'il contient assez de données.
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return fail(ERR_FSEEK_END, "fseek fin de fichier impossible");
    }
    long fsz = ftell(fp);
    if (fsz < 0) {
        fclose(fp);
        return fail(ERR_FTELL, "ftell a échoué");
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return fail(ERR_FSEEK_SET, "fseek début de fichier impossible");
    }

    // Le header minimal = 8 octets (w,h)
    if (fsz < 8) {
        fclose(fp);
        return fail(ERR_FILE_TOO_SMALL, "Fichier trop petit (< 8 octets)");
    }

    uint32_t w_raw = 0, h_raw = 0;
    if (fread(&w_raw, sizeof(uint32_t), 1, fp) != 1 ||
        fread(&h_raw, sizeof(uint32_t), 1, fp) != 1) {
        fclose(fp);
        return fail(ERR_READ_HEADER, "Lecture largeur/hauteur impossible");
    }

    uint32_t w = w_raw, h = h_raw;
    bool swapped = false;

    // Vérif “format plausible”
    bool w_ok = (w >= WIDTH_MIN  && w <= WIDTH_MAX);
    bool h_ok = (h >= HEIGHT_MIN && h <= HEIGHT_MAX);

    // Si c’est pas plausible, on tente un swap32 (endianness inversée)
    if (!(w_ok && h_ok)) {
        uint32_t w2 = swap32(w_raw);
        uint32_t h2 = swap32(h_raw);
        if (w2 >= WIDTH_MIN && w2 <= WIDTH_MAX &&
            h2 >= HEIGHT_MIN && h2 <= HEIGHT_MAX) {
            w = w2;
            h = h2;
            swapped = true;
        } else {
            fclose(fp);
            return fail(ERR_DIM_OUT_OF_RANGE, "Largeur/hauteur hors bornes [100..1000]");
        }
    }

    // Combien de pixels sont disponibles dans le fichier ?
    long avail_bytes = fsz - 8;
    long avail_elems = avail_bytes / 4;              // 1 pixel = 4 octets (uint32)
    long expected    = (long)w * (long)h;            // nb pixels attendus

    if (avail_elems < expected) {
        fclose(fp);
        return fail(ERR_NOT_ENOUGH_PIXELS, "Pas assez de pixels dans le fichier");
    } else if (avail_elems > expected) {
        // On ne plante pas : on ignore les pixels extra (fichier plus long que prévu)
        warn_msg("Trop de pixels: les pixels excédentaires seront ignorés");
    }

    // Allocation du buffer image
    uint32_t *pix = (uint32_t *)malloc((size_t)expected * sizeof(uint32_t));
    if (!pix) {
        fclose(fp);
        return fail(ERR_ALLOC_PIXELS, "Allocation mémoire pixels impossible");
    }

    // Lecture des pixels attendus
    size_t nr = fread(pix, sizeof(uint32_t), (size_t)expected, fp);
    fclose(fp);

    if (nr != (size_t)expected) {
        free(pix);
        return fail(ERR_READ_PIXELS, "Lecture pixels incomplète");
    }

    // Si endianness inversée : on swap chaque pixel
    if (swapped) {
        for (long i = 0; i < expected; ++i) {
            pix[i] = swap32(pix[i]);
        }
    }

    pm_out->width  = w;
    pm_out->height = h;
    pm_out->pix    = pix;
    return 0;
}

// ------------------------------------------------------------
// Image intégrale (summed-area table)
// On construit ii de taille (H+1)*(W+1) pour simplifier les formules.
// Ensuite, somme d’un rectangle = O(1).
//
// Pourquoi on fait ça ?
// Parce que chercher le meilleur carré BallSize x BallSize naïvement
// serait plus lent (re-sommer tous les pixels à chaque position).
// Ici, chaque score de carré se calcule en 4 accès mémoire.
// ------------------------------------------------------------
static int build_integral_from_mask(const uint8_t *mask, int W, int H, int **out_ii)
{
    *out_ii = NULL;
    size_t SZ = (size_t)(W + 1) * (size_t)(H + 1);
    int *ii = (int *)calloc(SZ, sizeof(int));
    if (!ii) {
        return fail(ERR_ALLOC_INTEGRAL, "Allocation mémoire intégrale impossible");
    }

    // Construction ligne par ligne
    for (int y = 1; y <= H; ++y) {
        int rowsum = 0;
        const uint8_t *row = mask + (size_t)(y - 1) * W;
        int *out      = ii + (size_t)y * (W + 1);
        int *out_prev = ii + (size_t)(y - 1) * (W + 1);

        for (int x = 1; x <= W; ++x) {
            rowsum += (int)row[x - 1];
            out[x] = out_prev[x] + rowsum;
        }
    }

    *out_ii = ii;
    return 0;
}

// Somme dans le rectangle [x0..x0+w-1], [y0..y0+h-1] à partir de l’image intégrale
static inline int rect_sum_ii(const int *ii, int W, int x0, int y0, int w, int h)
{
    int x1 = x0 + w;
    int y1 = y0 + h;

    const int *A = ii + (size_t)y0 * (W + 1) + x0;
    const int *B = ii + (size_t)y0 * (W + 1) + x1;
    const int *C = ii + (size_t)y1 * (W + 1) + x0;
    const int *D = ii + (size_t)y1 * (W + 1) + x1;

    return *D - *B - *C + *A;
}

// ------------------------------------------------------------
// Recherche du meilleur carré (position de boule)
// On glisse une fenêtre BallSize x BallSize sur le rectangle du billard,
// et on garde la position qui maximise le score (nb pixels du masque).
// ------------------------------------------------------------
static bool find_best_square(const int *ii, int W, int H,
                            const BillardRect *R, int ballSize,
                            int *bestX, int *bestY, int *bestScore)
{
    // On clamp le rectangle au cas où
    int xmin = R->Cmin;
    int xmax = R->Cmax;
    int ymin = R->Lmin;
    int ymax = R->Lmax;

    if (xmin < 0) xmin = 0;
    if (ymin < 0) ymin = 0;
    if (xmax > W - 1) xmax = W - 1;
    if (ymax > H - 1) ymax = H - 1;

    // Taille de la zone de recherche
    int Wwin = xmax - xmin + 1;
    int Hwin = ymax - ymin + 1;

    // Si la fenêtre ne tient même pas dans le billard => impossible de trouver une boule
    if (Wwin < ballSize || Hwin < ballSize) {
        return false;
    }

    int localBest = -1;
    int bx = -1, by = -1;

    // Balayage : chaque score se calcule en O(1) grâce à rect_sum_ii()
    for (int y = ymin; y <= ymax - ballSize + 1; ++y) {
        for (int x = xmin; x <= xmax - ballSize + 1; ++x) {
            int s = rect_sum_ii(ii, W, x, y, ballSize, ballSize);
            if (s > localBest) {
                localBest = s;
                bx = x;
                by = y;
            }
        }
    }

    if (localBest < 0) {
        return false;
    }

    *bestX = bx;
    *bestY = by;
    *bestScore = localBest;
    return true;
}

// ------------------------------------------------------------
// Programme principal
// ------------------------------------------------------------
int main(int argc, char **argv)
{
    int rc = 0;

    // Toutes les allocations seront libérées dans cleanup (même si erreur en plein milieu).
    // C’est une façon simple d’éviter les fuites mémoire sans écrire 50 frees partout.
    Pixmap pm = (Pixmap){0,0,NULL};
    uint8_t *maskR = NULL, *maskY = NULL, *maskW = NULL;
    int *iiR = NULL, *iiY = NULL, *iiW = NULL;

    // Paramètres : le programme + 29 entiers => argc doit faire 30
    if (argc != 30) {
        usage();
        rc = fail(ERR_BAD_ARGC, "argc=%d (attendu 30)", argc);
        goto cleanup;
    }

    bool ok = true;
    long v = 0;
    int idx = 1; // argv[0] = nom du programme, donc on démarre à 1

    // -----------------------------
    // Rectangle intérieur du billard
    // -----------------------------
    BillardRect rect = {0};

    v = parse_long(argv[idx++], &ok);
    if (!ok) { rc = fail(ERR_PARSE_LMIN, "Paramètre Lmin invalide: '%s'", argv[idx-1]); goto cleanup; }
    rect.Lmin = (int)v;

    v = parse_long(argv[idx++], &ok);
    if (!ok) { rc = fail(ERR_PARSE_LMAX, "Paramètre Lmax invalide: '%s'", argv[idx-1]); goto cleanup; }
    rect.Lmax = (int)v;

    v = parse_long(argv[idx++], &ok);
    if (!ok) { rc = fail(ERR_PARSE_CMIN, "Paramètre Cmin invalide: '%s'", argv[idx-1]); goto cleanup; }
    rect.Cmin = (int)v;

    v = parse_long(argv[idx++], &ok);
    if (!ok) { rc = fail(ERR_PARSE_CMAX, "Paramètre Cmax invalide: '%s'", argv[idx-1]); goto cleanup; }
    rect.Cmax = (int)v;

    // -----------------------------
    // Seuils RGB pour 4 “couleurs”
    // (Red, Yellow, White, BlueBG)
    //
    // BlueBG n’est pas utilisé pour détecter les boules ici,
    // mais il fait partie du format d’arguments du projet.
    // -----------------------------
    ColorRange crRed, crYellow, crWhite, crBlue;

    // Petite astuce: crs pointe vers les 6 champs de chaque struct.
    // Ça évite d’écrire 24 fois le même code de parsing.
    int *crs[4][6] = {
        { &crRed.rmin,    &crRed.rmax,    &crRed.gmin,    &crRed.gmax,    &crRed.bmin,    &crRed.bmax },
        { &crYellow.rmin, &crYellow.rmax, &crYellow.gmin, &crYellow.gmax, &crYellow.bmin, &crYellow.bmax },
        { &crWhite.rmin,  &crWhite.rmax,  &crWhite.gmin,  &crWhite.gmax,  &crWhite.bmin,  &crWhite.bmax },
        { &crBlue.rmin,   &crBlue.rmax,   &crBlue.gmin,   &crBlue.gmax,   &crBlue.bmin,   &crBlue.bmax }
    };

    const char *names[4] = { "Red", "Yellow", "White", "BlueBG" };

    // Lecture des 4 ranges de couleurs (4 * 6 entiers)
    for (int c = 0; c < 4; ++c) {
        for (int k = 0; k < 6; ++k) {
            v = parse_long(argv[idx++], &ok);
            if (!ok) {
                // Codes -16..-39 pour identifier exactement quel champ a planté
                int code = ERR_PARSE_COLOR_BASE - (c*6 + k);
                rc = fail(code, "Paramètre %s[%d] invalide: '%s'", names[c], k, argv[idx-1]);
                goto cleanup;
            }
            *crs[c][k] = (int)v;
        }
    }

    // -----------------------------
    // Taille du carré BallSize x BallSize (diamètre estimé de la boule)
    // -----------------------------
    v = parse_long(argv[idx++], &ok);
    if (!ok) { rc = fail(ERR_PARSE_BALLSIZE, "Paramètre BallSize invalide: '%s'", argv[idx-1]); goto cleanup; }
    int ballSize = (int)v;

    if (ballSize < BALLSIZE_MIN || ballSize > BALLSIZE_MAX) {
        rc = fail(ERR_BALLSIZE_RANGE, "BallSize=%d en dehors de [%d..%d]", ballSize, BALLSIZE_MIN, BALLSIZE_MAX);
        goto cleanup;
    }

    // -----------------------------
    // Lecture de l'image (pixmap.bin)
    // -----------------------------
    rc = read_pixmap(&pm);
    if (rc != 0) goto cleanup;

    // Double-sécurité: même après read_pixmap, on recheck (format projet)
    if (pm.width  < WIDTH_MIN  || pm.width  > WIDTH_MAX ||
        pm.height < HEIGHT_MIN || pm.height > HEIGHT_MAX) {
        rc = fail(ERR_IMAGE_BOUNDS, "Largeur/hauteur en dehors des bornes [100..1000]");
        goto cleanup;
    }

    // -----------------------------
    // Vérification du rectangle du billard
    // On veut un rectangle cohérent et à l’intérieur de l’image.
    // -----------------------------
    if (rect.Lmin < 0 || rect.Lmax < 0 ||
        rect.Cmin < 0 || rect.Cmax < 0 ||
        rect.Lmin > rect.Lmax ||
        rect.Cmin > rect.Cmax ||
        rect.Lmax >= (int)pm.height ||
        rect.Cmax >= (int)pm.width) {
        rc = fail(ERR_RECT_INVALID, "Rectangle du billard invalide");
        goto cleanup;
    }

    int W = (int)pm.width;
    int H = (int)pm.height;
    size_t N = (size_t)W * (size_t)H;

    // -----------------------------
    // Masques binaires (0/1) pour les 3 boules
    // maskR[p]=1 si pixel p est “dans la plage rouge”
    // -----------------------------
    maskR = (uint8_t *)calloc(N, 1);
    maskY = (uint8_t *)calloc(N, 1);
    maskW = (uint8_t *)calloc(N, 1);
    if (!maskR || !maskY || !maskW) {
        rc = fail(ERR_ALLOC_MASKS, "Allocation masques impossible");
        goto cleanup;
    }

    // Remplissage des masques, uniquement dans le rectangle du billard.
    // (Ça évite de détecter “des boules” dans les bordures / UI / hors table.)
    for (int y = rect.Lmin; y <= rect.Lmax; ++y) {
        size_t base = (size_t)y * W;
        for (int x = rect.Cmin; x <= rect.Cmax; ++x) {
            uint32_t p = pm.pix[base + (size_t)x];
            int R = getR(p);
            int G = getG(p);
            int B = getB(p);

            // Note: un même pixel peut matcher plusieurs ranges si les seuils se chevauchent.
            // Dans la pratique, on choisit des seuils propres pour éviter ça.
            if (R >= crRed.rmin && R <= crRed.rmax &&
                G >= crRed.gmin && G <= crRed.gmax &&
                B >= crRed.bmin && B <= crRed.bmax) {
                maskR[base + (size_t)x] = 1;
            }

            if (R >= crYellow.rmin && R <= crYellow.rmax &&
                G >= crYellow.gmin && G <= crYellow.gmax &&
                B >= crYellow.bmin && B <= crYellow.bmax) {
                maskY[base + (size_t)x] = 1;
            }

            if (R >= crWhite.rmin && R <= crWhite.rmax &&
                G >= crWhite.gmin && G <= crWhite.gmax &&
                B >= crWhite.bmin && B <= crWhite.bmax) {
                maskW[base + (size_t)x] = 1;
            }
        }
    }

    // -----------------------------
    // Construction des images intégrales
    // (permet de scorer un carré en O(1))
    // -----------------------------
    rc = build_integral_from_mask(maskR, W, H, &iiR);
    if (rc != 0) goto cleanup;
    rc = build_integral_from_mask(maskY, W, H, &iiY);
    if (rc != 0) goto cleanup;
    rc = build_integral_from_mask(maskW, W, H, &iiW);
    if (rc != 0) goto cleanup;

    // -----------------------------
    // Recherche du meilleur carré BallSize x BallSize pour chaque couleur
    // -----------------------------
    int bxR = -1, byR = -1, scR = 0;
    bool okR = find_best_square(iiR, W, H, &rect, ballSize, &bxR, &byR, &scR);

    int bxY = -1, byY = -1, scY = 0;
    bool okY = find_best_square(iiY, W, H, &rect, ballSize, &bxY, &byY, &scY);

    int bxW = -1, byW = -1, scW = 0;
    bool okW = find_best_square(iiW, W, H, &rect, ballSize, &bxW, &byW, &scW);

    // Valeurs de sortie par défaut : “non trouvé”
    int outXR = -1, outYR = -1, outSR = 0;
    int outXY = -1, outYY = -1, outSY = 0;
    int outXW = -1, outYW = -1, outSW = 0;

    // On n’accepte la détection que si le score dépasse un minimum.
    // (sinon, le “meilleur carré” pourrait juste être du bruit)
    if (okR && scR >= BALL_MIN_SCORE) { outXR = bxR; outYR = byR; outSR = scR; }
    if (okY && scY >= BALL_MIN_SCORE) { outXY = bxY; outYY = byY; outSY = scY; }
    if (okW && scW >= BALL_MIN_SCORE) { outXW = bxW; outYW = byW; outSW = scW; }

    // Petit bilan (informatif)
    int nb_found = 0;
    if (outXR != -1) nb_found++;
    if (outXY != -1) nb_found++;
    if (outXW != -1) nb_found++;

    if (nb_found < 3) {
        // On avertit mais on continue: MATLAB saura gérer -1 en “pas vu”
        warn_msg("Moins que 3 boules détectées, valeurs manquantes mises à -1,-1,0");
    }

    // -----------------------------
    // Écriture du fichier pos.txt (format imposé)
    // -----------------------------
    FILE *fo = fopen(OUTPUT_FILENAME, "w");
    if (!fo) {
        rc = fail(ERR_OPEN_OUTPUT, "Impossible d'écrire '%s': %s", OUTPUT_FILENAME, strerror(errno));
        goto cleanup;
    }

    fprintf(fo, "Red: %d, %d, %d\n",    outXR, outYR, outSR);
    fprintf(fo, "Yellow: %d, %d, %d\n", outXY, outYY, outSY);
    fprintf(fo, "White: %d, %d, %d\n",  outXW, outYW, outSW);
    fclose(fo);

    // Tout s’est bien passé
    rc = 0;

cleanup:
    // On libère TOUT ce qui a pu être alloué,
    // même si on a quitté au milieu (goto cleanup).
    free(pm.pix);
    free(maskR); free(maskY); free(maskW);
    free(iiR);   free(iiY);   free(iiW);

    // IMPORTANT: exit code stable (0 si OK, sinon positif)
    return rc_to_exit_code(rc);
}

