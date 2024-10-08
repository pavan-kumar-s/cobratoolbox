function [optKnockSol, bilevelMILPproblem] = OptKnock(model, selectedRxnList, options, constrOpt, prevSolutions, verbFlag, solutionFileNameTmp)
% Runs `OptKnock` in the most general form
%
% USAGE:
%
%    OptKnock(model, selectedRxnList, options, constrOpt, prevSolutions, verbFlag, solutionFileNameTmp)
%
% INPUTS:
%    model:                   Structure containing all necessary variables to described a
%                             stoichiometric model
%
%                               *  `rxns` - Rxns in the model
%                               *  `mets` - Metabolites in the model
%                               *  `S` - Stoichiometric matrix (sparse)
%                               *  `b` - RHS of Sv = b (usually zeros)
%                               *  `c` - Objective coefficients
%                               *  `lb` - Lower bounds for fluxes
%                               *  `ub` - Upper bounds for fluxes
%                               *  `rev` - Reversibility of fluxes
%
%    selectedRxnList:         n x 1 cell array where each cell is a reaction in model.rxns that can be knocked-out in OptKnock
%
% OPTIONAL INPUTS:
%    options:                `OptKnock` options
%
%                              *  `targetRxn` - Target flux to be maximized
%                              *  `numDel` - # of deletions allowed (Default: 5)
%                              *  `numDelSense` - Direction of # of deletions constraint (G/E/L)
%                                 (Default: L)
%                              *  `vMax` - Max flux (Default: 1000)
%                              *  `solveOptKnock` - Solve problem within Matlab (Default: true)
%                              *  `createGams` - Create GAMS input file
%                              *  `gamsFile` - GAMS input file name
%    constrOpt:              Explicitly constrained reaction options
%
%                              *  `rxnList` - Reaction list
%                              *  `values` - Values for constrained reactions
%                              *  `sense` - Constraint senses for constrained reactions (G/E/L)
%    prevSolutions:          Previous solutions
%    verbFlag:               Verbose flag
%    solutionFileNameTmp:    File name for storing temporary solutions
%
% OUTPUTS:
%    optKnockSol:            `optKnock` solution structure
%                            This is the same as the solution Structure
%                            from solveCobraMILP plus the following fields
%                            (if a solution exists):
%                            .rxnList - Reaction `KO` list
%                            .fluxes - the flux distribution 
%    bilevelMILPproblem:     `optKnock` problem structure
%
% .. Authors:
%       - Markus Herrgard 3/28/05
%       - Richard Que 04/27/10 - Added some default parameters.
%
% OptKnock uses bounds of `-vMax` to `vMax` or 0 to `vMax` for reversible and
% irreversible reactions. If you wish to constrain a reaction, use
% `constrOpt`.

if isfield(model,'C') || isfield(model,'E')
    issueConfirmationWarning('optKnock does not handle the additional constraints and variables defined in the model structure (fields .C and .E.)\n It will only use the stoichiometry provided.');
end


global MILPproblemType;
global selectedRxnIndIrrev;
global rxnList;
global irrev2rev;
global solutionFileName;
global biomassRxnID;
global OptKnockKOrxnList;
global OptKnockObjective;
global OptKnockGrowth;
global solID;
% Set these above for MILP callbacks
%idefault <= 5 deletions; solve OptKnock
if (~exist('options','var') || isempty(options) )
    error('OptKnock: No target reaction specified')
else
    if ~isfield(options,'vMax'), options.vMax = 1000; end
    if ~isfield(options,'numDel'), options.numDel = 5; end
    if ~isfield(options,'numDelSense'), options.numDelSense = 'L'; end
    if ~isfield(options,'solveOptKnock'), options.solveOptKnock = true; end
end

if ~exist('constrOpt','var')
    constrOpt.rxnInd = [];
    constrOpt.values = [];
    constrOpt.sense = [];
    constrOpt.rxnList = [];
end

if (nargin < 5)
    prevSolutions = [];
end
if (nargin < 6)
    verbFlag = false;
end
if (nargin < 7)
    solutionFileName = 'optKnockSolutions.mat';
else
    solutionFileName = solutionFileNameTmp;
end

if ~isfield(options,'targetRxn') || any(~ismember(options.targetRxn,model.rxns))
    if ~isfield(options, 'targetRxn')
        error('No target reaction (options.targetRxn) defined')
    else
        error('The reaction %s is not part of the model. Try using searchModel(model, ''%s'') to find reactions with a similar name.',options.targetRxn,options.targetRxn);
    end
end
% Convert to irreversible rxns
[modelIrrev,matchRev,rev2irrev,irrev2rev] = convertToIrreversible(model,'OrderReactions',true);

% Create the index of the previous KO's suggested by OptKnock to avoid obtaining the same
% solution again
selPrevSolIrrev = [];
for i = 1:length(prevSolutions)
    prevSolRxnList = prevSolutions{i};
    if ~isempty(prevSolRxnList)
        selPrevSol = ismember(model.rxns,prevSolRxnList);
        selPrevSolIrrev(:,i) = selPrevSol(irrev2rev);
    end
end

[~,nRxns] = size(modelIrrev.S);

% Create matchings for reversible reactions in the set selected for KOs
% This is to ensure that both directions of the reaction are knocked out
selSelectedRxn = ismember(model.rxns,selectedRxnList);
selSelectedRxnIrrev = selSelectedRxn(irrev2rev);
selectedRxnIndIrrev = find(selSelectedRxnIrrev);
cnt = 0;
nSelected = length(selectedRxnIndIrrev);
selRxnCnt = 1;
while selRxnCnt <= nSelected
    rxnID = selectedRxnIndIrrev(selRxnCnt);
    if (matchRev(rxnID)>0)
        cnt = cnt + 1;
        selectedRxnMatch(cnt,1) = selRxnCnt;
        selectedRxnMatch(cnt,2) = selRxnCnt+1;
        selRxnCnt = selRxnCnt + 1;
    end
    selRxnCnt = selRxnCnt + 1;
end

% Set inner constraints for the LP
constrOptIrrev = setConstraintsIrrevModel(constrOpt,model,modelIrrev,rev2irrev);

% Set objectives for linear and integer parts
cLinear = zeros(nRxns,1);
cInteger = zeros(sum(selSelectedRxnIrrev),1);

% Set the correct objective coefficient
targetRxnID = find(ismember(model.rxns,options.targetRxn));
targetRxnIDirrev = rev2irrev{targetRxnID}(1);
cLinear(targetRxnIDirrev) = 1;

% Create the constraint matrices for the bilevel MILP
bilevelMILPproblem = createBilevelMILPproblem(modelIrrev,cLinear,cInteger,selSelectedRxnIrrev,...
    selectedRxnMatch,constrOptIrrev,[],options,selPrevSolIrrev);

% Initial guess (random)
%bilevelMILPproblem.x0 = round(rand(length(bilevelMILPproblem.c),1));
if isfield(options,'initSolution')
    if (length(options.initSolution) > options.numDel || ~all(ismember(options.initSolution,selectedRxnList)))
        warning('Initial solution not valid - starting from a random initial solution')
        bilevelMILPproblem.x0 = [];
    else
        % Set initial integer solution
        selInitRxn = ismember(model.rxns,options.initSolution);
        selInitRxnIrrev = selInitRxn(irrev2rev);
        initRxnIndIrrev = find(selInitRxnIrrev);
        initIntegerSol = ~ismember(selectedRxnIndIrrev,initRxnIndIrrev);
        selInteger = bilevelMILPproblem.vartype == 'B';
        [~,nVar] = size(bilevelMILPproblem.A);
        bilevelMILPproblem.x0 = nan(nVar,1);
        bilevelMILPproblem.x0(selInteger) = initIntegerSol;
    end
else
    bilevelMILPproblem.x0 = [];
end

% Maximize
bilevelMILPproblem.osense = -1;

if (verbFlag)
    [nConstr,nVar] = size(bilevelMILPproblem.A);
    nInt = length(bilevelMILPproblem.intSolInd);
    fprintf('MILP problem with %d constraints %d integer variables and %d continuous variables\n',...
        nConstr,nInt,nVar);
end

bilevelMILPproblem.model = modelIrrev;

% Set these for CPLEX callbacks
MILPproblemType = 'OptKnock';
rxnList = model.rxns;
biomassRxnID = find(modelIrrev.c==1);
solID = 0;
OptKnockObjective = [];
OptKnockGrowth = [];
OptKnockKOrxnList = {};

% Solve problem
if (options.solveOptKnock)
    optKnockSol = solveCobraMILP(bilevelMILPproblem,'printLevel',verbFlag);
    if (~isempty(optKnockSol.cont))
        optKnockSol.fluxes = convertIrrevFluxDistribution(optKnockSol.cont(1:length(matchRev)),matchRev);
    end
    if (~isempty(optKnockSol.int))
        % Figure out the KO reactions
        optKnockRxnInd = selectedRxnIndIrrev(optKnockSol.int < getCobraSolverParams('LP', 'feasTol')*100);
        optKnockSol.rxnList = model.rxns(unique(irrev2rev(optKnockRxnInd)));
    end
else
    optKnockSol.rxnList = {};
    optKnockSol.fluxes = [];
end
