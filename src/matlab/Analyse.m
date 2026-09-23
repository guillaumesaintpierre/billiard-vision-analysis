%Louis Gosset, Joseph Belamich, Guillaume Saint-Pierre
% ============================
% MAIN
% ============================
%
% Idée générale:
% On reçoit les positions (X,Y) des 3 boules sur une séquence (une frame = un point).
% Le tracking peut rater (valeurs -1 ou NaN) et parfois faire des "pics" (outliers).
% On nettoie donc les données, puis on:
%  - détermine quelle boule est la 1re à bouger
%  - détermine quand la 2e puis la 3e boule commencent à bouger
%  - compte combien de bandes la 1re boule touche ENTRE ces deux instants
%  - affiche un "score sheet"
%  - écrit un SummaryXX.txt au format imposé (très important pour l'évaluation)
%
% Hypothèses de projet:
% - Si une boule n'est pas trouvée: -1 (ou NaN) => boule "cachée", on suppose immobile
% - Pas de boucle for/while "inutile" dans la logique globale (on vectorise autant que possible)

% Les variables suivantes doivent exister avant d'exécuter ce script :
% seqName, Xr, Yr, Xy, Yy, Xw, Yw, reboundColorWin, reboundColorLoss,
% BallBorderDist, MoveDistPx, BallminScore

% ------------------------------------------------------------
% 1) Vérifications d'entrée (on préfère planter tôt avec un message clair)
% ------------------------------------------------------------
assertVectorSameLength(Xr, Yr, 'Xr', 'Yr');
assertVectorSameLength(Xy, Yy, 'Xy', 'Yy');
assertVectorSameLength(Xw, Yw, 'Xw', 'Yw');

% Option stricte : toutes les séries doivent avoir la même longueur (même nombre de frames)
L = [numel(Xr), numel(Xy), numel(Xw)];
if numel(unique(L)) ~= 1
    error('Analyse:LengthMismatchAll', ...
        'Toutes les séries doivent avoir la même longueur. Longueurs = [%s].', num2str(L));
end

% Couleurs utilisées pour dessiner les rebonds selon le verdict (Win/Loss)
reboundColorWin  = validateMatlabColor(reboundColorWin,  'reboundColorWin');
reboundColorLoss = validateMatlabColor(reboundColorLoss, 'reboundColorLoss');

% ------------------------------------------------------------
% 2) Conversion "valeurs manquantes" -> NaN
% ------------------------------------------------------------
% Dans la partie C / LabVIEW, une boule non trouvée sort souvent en -1,-1.
% Ici on transforme ça en NaN pour pouvoir traiter proprement ensuite.
Xr(Xr==-1)=NaN;  Xy(Xy==-1)=NaN;  Xw(Xw==-1)=NaN;
Yr(Yr==-1)=NaN;  Yy(Yy==-1)=NaN;  Yw(Yw==-1)=NaN;

% ------------------------------------------------------------
% 3) Changement de repère: LabVIEW (0,0 en haut-gauche) -> Matlab (0,0 en bas-gauche)
% ------------------------------------------------------------
H = 480;                     % hauteur image en pixels (donnée du projet)
[Yr, Yy, Yw] = flipY(Yr, Yy, Yw, H);

% ------------------------------------------------------------
% 4) Nettoyage des trajectoires
% ------------------------------------------------------------
% Étape A: combler les trous (NaN) par la PROCHAINE valeur valide.
% Interprétation: "si elle est cachée quelques frames, on suppose qu'elle n'a pas bougé".
[Xr, Yr] = InterpolateNan(Xr, Yr);
[Xy, Yy] = InterpolateNan(Xy, Yy);
[Xw, Yw] = InterpolateNan(Xw, Yw);

% Étape B: enlever les "pics" de tracking (outliers).
% Règle: un vrai outlier doit être détecté en X ET en Y, sinon on évite de corriger trop agressivement.
% Correction: on remplace par la valeur précédente (ça "recolle" la trajectoire).
[Xr, Yr] = RemoveOutlier(Xr, Yr);
[Xy, Yy] = RemoveOutlier(Xy, Yy);
[Xw, Yw] = RemoveOutlier(Xw, Yw);

% Étape C: distances parcourues (info affichée dans le PDF)
dR = GetBallPathLength(Xr, Yr);
dY = GetBallPathLength(Xy, Yy);
dW = GetBallPathLength(Xw, Yw);

% ------------------------------------------------------------
% 5) Déduire le "cadre" (les limites du billard) depuis les traces
% ------------------------------------------------------------
% Ici on prend simplement min/max de toutes les positions mesurées.
[Xmin, Xmax, Ymin, Ymax] = GetFrame(Xr, Yr, Xy, Yy, Xw, Yw);

% ------------------------------------------------------------
% 6) Trouver l'ordre des boules: qui commence à bouger en premier ?
% ------------------------------------------------------------
% On dit qu'une boule "a bougé" dès qu'elle s'éloigne de son point initial de > MoveDistPx.
iR = GetFirstMoveIdx(Xr, Yr, MoveDistPx);
iY = GetFirstMoveIdx(Xy, Yy, MoveDistPx);
iW = GetFirstMoveIdx(Xw, Yw, MoveDistPx);

% On met Inf si une boule ne bouge jamais (plus simple à trier)
idx = [inf inf inf];
if ~isempty(iR), idx(1)=iR; end
if ~isempty(iY), idx(2)=iY; end
if ~isempty(iW), idx(3)=iW; end

% Tie-break "humain": si 2 boules démarrent au même index, on prend celle
% dont le tout premier segment est le plus long (ça évite de choisir une boule
% qui bouge à peine à cause du bruit).
seg1 = [seglen1(Xr,Yr), seglen1(Xy,Yy), seglen1(Xw,Yw)];
mins = find(idx == min(idx));
[~, pick] = max(seg1(mins));
firstBall = mins(pick);    % 1=R, 2=Y, 3=W

% On récupère directement la série (X,Y) de la 1re boule
switch firstBall
  case 1, X = Xr; Y = Yr; firstName = 'red';
  case 2, X = Xy; Y = Yy; firstName = 'yellow';
  case 3, X = Xw; Y = Yw; firstName = 'white';
end
colorNames    = {'red','yellow','white'};
firstBallName = colorNames{firstBall};

% Indices de début de mouvement (Inf si jamais bougé)
fm = [inf inf inf];
if ~isempty(iR), fm(1)=iR; end
if ~isempty(iY), fm(2)=iY; end
if ~isempty(iW), fm(3)=iW; end
iMoveFirst = fm(firstBall); 

% ------------------------------------------------------------
% 7) Déterminer "2e boule" et "3e boule" via l'ordre de début de mouvement
% ------------------------------------------------------------
[iSecond, iThird, secondBall, thirdBall] = SecondThirdByMove(fm, firstBall); 

% ------------------------------------------------------------
% 8) Détection des rebonds (touches de bandes) pour la 1re boule
% ------------------------------------------------------------
% iTouch = indices où on considère qu'il y a "rebond".
% La logique est expliquée dans GetTouchIdx():
%   - on repère les instants où la boule est proche d'une bande
%   - et on cherche un changement de signe de vitesse "normale" (rebond réel)
%   - fallback: si pas de changement de signe (rebond glissé), on prend le début
%     d'une grappe de points proches du bord
%   - petit anti-bruit ("debounce") pour éviter de compter 3 fois le même rebond
iTouch = GetTouchIdx(X, Y, Xmin, Xmax, Ymin, Ymax, BallBorderDist);

% ------------------------------------------------------------
% 9) Compter les bandes touchées ENTRE la 2e et la 3e boule (début mouvement)
% ------------------------------------------------------------
nbBandsBetween = 0;
if isfinite(iSecond) && isfinite(iThird) && iThird > iSecond
    nbBandsBetween = nnz( (iTouch >= iSecond) & (iTouch < iThird) );
end

% Verdict du point: gagné si >=3 bandes entre ces deux instants
if isfinite(iSecond) && isfinite(iThird) && (nbBandsBetween >= 3)
    VD = "Win";
else
    VD = "Loss";
end

% Couleur d'affichage des rebonds selon Win/Loss
isWin = strcmpi(char(VD), 'Win');
if isWin
    reboundColor = reboundColorWin;
else
    reboundColor = reboundColorLoss;
end

% Combien de boules ont bougé (utile dans le cartouche)
nbBallsMoved = sum(isfinite([iR iY iW]));

% ------------------------------------------------------------
% 10) Affichage "Scores sheet"
% ------------------------------------------------------------
fig = figure('Color','w','Visible','on'); hold on;
ax = gca; set(ax,'Color','w'); grid(ax,'off'); box(ax,'off');
ax.XTick = []; ax.YTick = []; ax.XMinorTick='off'; ax.YMinorTick='off';

% On ajoute un peu de marge pour pouvoir écrire du texte "sous" le billard
pad = 10; padB = 60;
axis([Xmin-pad, Xmax+pad, Ymin-padB, Ymax+pad]); axis equal; axis off;

% Cadre du billard
rectangle('Position',[Xmin Ymin (Xmax-Xmin) (Ymax-Ymin)], ...
          'EdgeColor','b','LineWidth',1);

% Traces (couleurs fixes pour lisibilité)
plot(Xr, Yr, 'r.-', 'LineWidth',1, 'MarkerSize',6, 'DisplayName','Red');
plot(Xy, Yy, 'y.-', 'LineWidth',1, 'MarkerSize',6, 'DisplayName','Yellow');
plot(Xw, Yw, 'b.-', 'LineWidth',1, 'MarkerSize',6, 'DisplayName','White');

% Point initial de chaque boule (étoile/hexagone) -> UNIQUEMENT si la boule a bougé
movedR = ~isempty(iR);
movedY = ~isempty(iY);
movedW = ~isempty(iW);

if movedR && isfinite(Xr(1)) && isfinite(Yr(1))
    plot(Xr(1), Yr(1), 'rh', 'MarkerSize',20, 'LineWidth',1.2, 'MarkerFaceColor','none');
end

if movedY && isfinite(Xy(1)) && isfinite(Yy(1))
    plot(Xy(1), Yy(1), 'yh', 'MarkerSize',20, 'LineWidth',1.2, 'MarkerFaceColor','none', ...
         'MarkerEdgeColor',[0.85 0.75 0]);
end

if movedW && isfinite(Xw(1)) && isfinite(Yw(1))
    plot(Xw(1), Yw(1), 'bh', 'MarkerSize',20, 'LineWidth',1.2, 'MarkerFaceColor','none');
end


% Rebonds UNIQUEMENT entre "2e bouge" et "3e bouge" (c'est ça qui décide Win/Loss)
iBetween = [];
if isfinite(iSecond) && isfinite(iThird) && iThird > iSecond && ~isempty(iTouch)
    iBetween = iTouch( (iTouch >= iSecond) & (iTouch < iThird) );
end
if ~isempty(iBetween)
    hReb = plot(X(iBetween), Y(iBetween), 'o', ...
        'MarkerSize', 20, 'LineWidth', 1.5, ...
        'MarkerFaceColor', 'none', ...
        'DisplayName', 'Rebound 2→3');
    set(hReb, 'Color', reboundColor, 'MarkerEdgeColor', reboundColor);
end

% Titre avec timestamp (pratique quand tu génères plusieurs PDF)
ts = datetime('now','Format','dd.MM.yyyy - HH:mm:ss');
title(sprintf('Scores sheet – %s – (%s)', seqName, string(ts)));

% Cartouche texte en bas
lineGap = 14;  y1 = Ymin - 8;  y2 = y1 - lineGap;  yDist = y1 - 2*lineGap - 2;
txtLeft = sprintf('Score sheet for "%s"\n--- %s ---', firstBallName, VD);
text(Xmin, y1, txtLeft, 'HorizontalAlignment','left','VerticalAlignment','top', ...
     'FontName','Helvetica','FontSize',10, 'Color','k', 'Clipping','off');

text(Xmax, y1, sprintf('%d ball(s) moved', nbBallsMoved), ...
     'HorizontalAlignment','right','VerticalAlignment','top', ...
     'FontName','Helvetica','FontSize',10, 'Color','k', 'Clipping','off');

text(Xmax, y2, sprintf('%d band(s) between 2nd->3rd move', nbBandsBetween), ...
     'HorizontalAlignment','right','VerticalAlignment','top', ...
     'FontName','Helvetica','FontSize',10, 'Color','k', 'Clipping','off');

text(Xmin,            yDist, sprintf('red_{d} : %0.0fpx',   dR), ...
     'HorizontalAlignment','left','VerticalAlignment','top', ...
     'FontName','Helvetica','FontSize',10, 'Color','k', 'Clipping','off');
text((Xmin+Xmax)/2.0, yDist, sprintf('yellow_{d} : %0.0fpx', dY), ...
     'HorizontalAlignment','center','VerticalAlignment','top', ...
     'FontName','Helvetica','FontSize',10, 'Color','k', 'Clipping','off');
text(Xmax,            yDist, sprintf('white_{d} : %0.0fpx', dW), ...
     'HorizontalAlignment','right','VerticalAlignment','top', ...
     'FontName','Helvetica','FontSize',10, 'Color','k', 'Clipping','off');

% ============================
% Résumé texte (format imposé)
% ============================
% IMPORTANT: ce fichier est parsé automatiquement par l'outil d'évaluation.
% Donc on respecte STRICTEMENT le format:
%   f:x; s:x; n:d; b:d; rb:d; yb:d; wb:d;
txtName = sprintf('Summary%s.txt', seqName);
fid = fopen(txtName,'w');
if fid < 0
    warning('⚠️ Impossible d''ouvrir %s en écriture.', txtName);
else
    % f : 1re boule (r,y,w)
    fLetters = {'r','y','w'};
    fChar = fLetters{firstBall};

    % s : score (w = win, l = loss)
    if strcmpi(char(VD), 'Win')
        sChar = 'w';
    else
        sChar = 'l';
    end

    % n : nb de boules ayant bougé
    nVal = nbBallsMoved;

    % b : nb de bords touchés par la 1re boule (TOUS les rebonds détectés)
    % (même ceux hors fenêtre 2→3) -> c'est ce qui est demandé dans le summary.
    bVal = numel(iTouch);

    % rb/yb/wb : distances parcourues (arrondies à l'entier)
    rbVal = round(dR);
    ybVal = round(dY);
    wbVal = round(dW);

    % Ligne EXACTE attendue
    line = sprintf('f:%s; s:%s; n:%d; b:%d; rb:%d; yb:%d; wb:%d;', ...
                   fChar, sChar, nVal, bVal, rbVal, ybVal, wbVal);

    fprintf(fid, '%s\n', line);
    fclose(fid);
    fprintf('✓ Résumé sauvegardé: %s\n', txtName);
end% ==== Sauvegardes ====
pdfName = sprintf('ScoreSheet%s.pdf', seqName);
try
    axtoolbar(ax,'none');
catch
end
drawnow;

try
    set(fig,'PaperPositionMode','auto');
    if exist('exportgraphics','file') == 2
        exportgraphics(fig, pdfName, 'ContentType','vector');
    else
        print(fig, pdfName, '-dpdf', '-bestfit');
    end
    fprintf('✓ PDF sauvegardé: %s\n', pdfName);
catch ME
    warning('⚠️ Échec de la sauvegarde PDF (%s): %s', pdfName, ME.message);
end

% ============================================================
% FONCTIONS (petites briques avec explications "humaines")
% ============================================================

function [Yr,Yy,Yw] = flipY(Yr,Yy,Yw, H)
% Inversion verticale des coordonnées Y
% LabVIEW: (0,0) en haut à gauche
% Matlab : (0,0) en bas à gauche
% Donc: y_matlab = H - y_labview
  Yr = H - Yr; Yy = H - Yy; Yw = H - Yw;
end

function vout = fillNext(v)
% Remplissage "next": chaque NaN prend la prochaine valeur valide.
% Exemple: [10 NaN NaN 13] -> [10 13 13 13]
    t = (1:numel(v)).';
    m = ~isnan(v);
    if ~any(m), vout = v; return, end
    vout = interp1(t(m), v(m), t, 'next', 'extrap');
end

function [X, Y] = InterpolateNan(X, Y)
% Remplit les NaN en X et Y avec la prochaine valeur valide (hypothèse: boule immobile si cachée)
    sx = size(X); sy = size(Y);
    X = X(:); Y = Y(:);
    X = fillNext(X);
    Y = fillNext(Y);
    X = reshape(X, sx);
    Y = reshape(Y, sy);
end

function [X, Y] = RemoveOutlier(X, Y)
% Enlève les outliers (pics) détectés simultanément en X et Y.
% Pourquoi X ET Y ?
% -> sinon un bruit sur une seule coordonnée risquerait de corriger à tort.
% Remplacement: valeur précédente (solution simple et robuste).
    sx = size(X); sy = size(Y);
    Xv = X(:);    Yv = Y(:);

    mX = isoutlier(Xv, 'movmedian', 10);
    mY = isoutlier(Yv, 'movmedian', 10);

    mask = find(mX & mY);      % indices où X ET Y sont outliers
    mask(mask == 1) = [];      % évite i-1 invalide

    if isempty(mask)
        X = reshape(Xv, sx);
        Y = reshape(Yv, sy);
        return;
    end

    mask = sort(mask);
    for k = 1:numel(mask)
        i = mask(k);
        Xv(i) = Xv(i-1);
        Yv(i) = Yv(i-1);
    end

    X = reshape(Xv, sx);
    Y = reshape(Yv, sy);
end

function PathLength = GetBallPathLength(X, Y)
% Distance totale parcourue = somme des distances entre points successifs
    X = X(:); Y = Y(:);
    if numel(X) < 2 || numel(Y) < 2, PathLength = 0; return, end
    dx = diff(X); dy = diff(Y);
    PathLength = sum(hypot(dx, dy));
end

function [Xmin, Xmax, Ymin, Ymax] = GetFrame(Xr, Yr, Xy, Yy, Xw, Yw)
% Cadre minimal englobant toutes les traces (min/max sur toutes les boules)
    Xall = [Xr(:); Xy(:); Xw(:)];
    Yall = [Yr(:); Yy(:); Yw(:)];
    Xmin = min(Xall); Xmax = max(Xall);
    Ymin = min(Yall); Ymax = max(Yall);
end

function [FirstMoveIdx, MoveDist] = GetFirstMoveIdx(X, Y, MoveDistPx)
% "Début de mouvement" = premier index où la boule s'éloigne du point initial
% d'une distance > MoveDistPx.
    if nargin < 3 || isempty(MoveDistPx), MoveDistPx = 9; end
    X = X(:); Y = Y(:);
    D = hypot(X - X(1), Y - Y(1));
    FirstMoveIdx = find(D > MoveDistPx, 1, 'first');
    if nargout >= 2
        MoveDist = hypot(diff(X), diff(Y)); 
    end
end

function L = seglen1(X, Y)
% Longueur du 1er segment (sert uniquement pour départager deux départs "simultanés")
    if numel(X) < 2
        L = 0;
    else
        L = hypot(X(2)-X(1), Y(2)-Y(1));
    end
end

function idx = firstOfRuns(mask)
% Renvoie l'index du 1er élément de chaque "grappe" de true consécutifs.
% Exemple: [0 1 1 0 1 1 1 0] -> [2 5]
    mask = mask(:);
    idx  = find(mask);
    if isempty(idx), return; end
    idx  = idx(:);
    keep = [true; diff(idx) > 1];
    idx  = idx(keep);
end

function IdxTouch = GetTouchIdx(X, Y, Xmin, Xmax, Ymin, Ymax, BallBorderDist)
% Détection "humaine" d'un rebond sur bande:
% 1) La boule doit être proche d'une bande (distance <= BallBorderDist).
% 2) Idéalement, on veut un rebond "réel": la vitesse perpendiculaire à la bande
%    change de signe (ex: va vers la gauche puis repart vers la droite).
% 3) Parfois le tracking ne donne pas un changement de signe propre (rebond glissé,
%    bruit, etc.). Dans ce cas, on prend le début de la grappe "proche du bord".
% 4) On applique un petit anti-doublon temporel (debounce) pour éviter de compter
%    4 rebonds quand la balle "tremble" sur le bord.
%
% Important pour ton cas "double rebond même bande":
% - Si la balle repart puis revient, il y aura deux changements de signe => 2 rebonds.
% - Si elle reste collée au bord sans vraie inversion de direction, on ne comptera
%   qu'un seul événement (début de grappe), ce qui est volontaire.

    if nargin < 7 || isempty(BallBorderDist), BallBorderDist = 9; end
    X = X(:); Y = Y(:);

    % Distances à chaque bande
    dL = X - Xmin;     dR = Xmax - X;
    dB = Y - Ymin;     dT = Ymax - Y;

    nearL = dL <= BallBorderDist;
    nearR = dR <= BallBorderDist;
    nearB = dB <= BallBorderDist;
    nearT = dT <= BallBorderDist;

    % Vitesses entre échantillons
    dx = diff(X);
    dy = diff(Y);

    % sign() renvoie 0 si dx=0, et ça casse la détection de changement de signe.
    % Donc on "remplace" les zéros par le signe voisin.
    sdx = signNoZero(dx);
    sdy = signNoZero(dy);

    % Changements de signe: indicateurs de rebond "propre"
    turnNegPosX = (sdx(1:end-1) < 0) & (sdx(2:end) > 0);  % allait vers -X puis +X => rebond à gauche
    turnPosNegX = (sdx(1:end-1) > 0) & (sdx(2:end) < 0);  % rebond à droite
    turnNegPosY = (sdy(1:end-1) < 0) & (sdy(2:end) > 0);  % rebond en bas
    turnPosNegY = (sdy(1:end-1) > 0) & (sdy(2:end) < 0);  % rebond en haut

    % +1 pour revenir à l'index "dans" X,Y (car turn est calculé sur diff)
    iL = find(turnNegPosX) + 1;  iL = iL(nearL(iL));
    iR = find(turnPosNegX) + 1;  iR = iR(nearR(iR));
    iB = find(turnNegPosY) + 1;  iB = iB(nearB(iB));
    iT = find(turnPosNegY) + 1;  iT = iT(nearT(iT));

    % Fallback: pas de changement de signe détectable => rebond "glissé" ou bruit
    if isempty(iL), iL = firstOfRuns(nearL); end
    if isempty(iR), iR = firstOfRuns(nearR); end
    if isempty(iB), iB = firstOfRuns(nearB); end
    if isempty(iT), iT = firstOfRuns(nearT); end

    % On ignore l'index 1 (souvent faux positif: position initiale déjà proche du bord)
    iL(iL==1) = []; iR(iR==1) = []; iB(iB==1) = []; iT(iT==1) = [];

    % Anti-doublons (si bruit): on force un espacement minimal entre événements
    minGap = 2; % en frames
    iL = debounceIdx(iL, minGap);
    iR = debounceIdx(iR, minGap);
    iB = debounceIdx(iB, minGap);
    iT = debounceIdx(iT, minGap);

    % Merge des rebonds détectés (unique = si un rebond coin doit compter 2 bandes, enlever unique())
    IdxTouch = sort(unique([iL; iR; iB; iT]));
end

function s = signNoZero(v)
% But: éviter les zéros dans sign(v), sinon un vrai rebond peut ne pas être vu.
% On remplit les 0 avec le signe précédent/suivant.
    s = sign(v);
    s(s==0) = NaN;
    s = fillmissing(s, 'previous');
    s = fillmissing(s, 'next');
    s(isnan(s)) = 0;
end

function idx = debounceIdx(idx, gap)
% Garde uniquement les événements espacés d'au moins "gap" frames.
% Exemple: [10 11 12 30] avec gap=2 -> [10 30]
    idx = idx(:);
    if isempty(idx), return; end
    keep = [true; diff(idx) > gap];
    idx = idx(keep);
end

function [iSecond, iThird, secondBall, thirdBall] = SecondThirdByMove(firstMoveIdx, firstBall)
% On veut "2e" et "3e" boules selon leur début de mouvement (pas selon la couleur).
% Si une boule ne bouge pas: Inf => on ne peut pas établir 2e/3e correctement.
    others = setdiff(1:3, firstBall);
    candIdx  = [firstMoveIdx(others(1)), firstMoveIdx(others(2))];
    candBall = [others(1),                 others(2)];
    m = isfinite(candIdx);

    if nnz(m) < 2
        iSecond = inf; iThird = inf; secondBall = NaN; thirdBall = NaN;
        return;
    end

    candIdx  = candIdx(m);
    candBall = candBall(m);
    [~,ord]  = sort(candIdx, 'ascend');
    candIdx  = candIdx(ord);
    candBall = candBall(ord);

    iSecond    = candIdx(1);
    iThird     = candIdx(2);
    secondBall = candBall(1);
    thirdBall  = candBall(2);
end

function assertVectorSameLength(X, Y, nameX, nameY)
% Petites vérifs "anti-galère":
% - numériques
% - vecteurs
% - pas vides
% - même taille
    if ~isnumeric(X) || ~isnumeric(Y)
        error('Analyse:TypeError', '%s et %s doivent être numériques.', nameX, nameY);
    end
    if ~isvector(X) || ~isvector(Y)
        error('Analyse:NotVector', '%s et %s doivent être des vecteurs.', nameX, nameY);
    end
    if isempty(X) || isempty(Y)
        error('Analyse:EmptyVector', '%s ou %s est vide.', nameX, nameY);
    end
    if numel(X) ~= numel(Y)
        error('Analyse:LengthMismatchPair', ...
            'Longueur différente: %s=%d, %s=%d.', nameX, numel(X), nameY, numel(Y));
    end
end

function c = validateMatlabColor(cIn, argName)
% Accepte:
%  - 'r','g','b','c','m','y','k','w'
%  - [r g b] avec r,g,b dans [0..1] (format Matlab)
%
% But: éviter de découvrir au milieu du script que la couleur est invalide.
    if isstring(cIn) && isscalar(cIn), cIn = char(cIn); end

    if ischar(cIn)
        if numel(cIn) ~= 1 || ~ismember(cIn, ['r','g','b','c','m','y','k','w'])
            error('Analyse:BadColorChar', ...
                '%s doit être une lettre parmi r g b c m y k w (ex: ''g'').', argName);
        end
        c = cIn;
        return
    end

    if isnumeric(cIn) && numel(cIn) == 3
        c = double(cIn(:)).';
        if any(~isfinite(c))
            error('Analyse:BadColorNaNInf', '%s contient NaN/Inf.', argName);
        end
        if any(c < 0 | c > 1)
            error('Analyse:BadColorRGB', ...
                '%s doit être [r g b] dans [0..1]. Reçu: [%g %g %g].', argName, c(1), c(2), c(3));
        end
        return
    end

    error('Analyse:BadColorType', ...
        '%s doit être une lettre (''g'') ou un RGB 1x3 dans [0..1].', argName);
end
