function [inflow,outflow] = calc_flows(t,yt,param,fixed_params)
    % calculate inflow and outflow from each compartment over time

    n_var = length(fixed_params.dbeta);
    
    yix = fixed_params.yix;
    nS = yix.nS; nD = yix.nD; nI = yix.nI; nR = yix.nR; nRW = yix.nRW;
    nUV = yix.nUV; nV1 = yix.nV1; nV2 = yix.nV2; nVS1 = yix.nVS1; nVS2 = yix.nVS2;
    
    % set vaccination to zero if compartment is below this threshold
    vacc_threshold = 1e-6;

    gamma = param.gamma; mu = param.mu;
    gamma_var = fixed_params.gamma_var; mu_var = fixed_params.mu_var;
    dbeta = fixed_params.dbeta; t_imm = fixed_params.t_imm;
    VE1 = fixed_params.VE1; VE2 = fixed_params.VE2;
    VE1V = fixed_params.VE1V'; VE2V = fixed_params.VE2V';
    VES1 = fixed_params.VES1; VES1V = fixed_params.VES1V';
    VES2 = fixed_params.VES2; VES2V = fixed_params.VES2V';
    k = fixed_params.k; kw = fixed_params.kw;

    gamma = [gamma gamma_var];
    mu = [mu mu_var];
    
    inflow =  zeros(size(yt));
    outflow = zeros(size(yt));
    for tidx = 1:size(yt,1)
        y = squeeze(yt(tidx,:,:));
        param = vary_params(t(tidx),param);

        V_total = sum(y([nV1 nV2 nVS1 nVS2],[nS nR nRW nI]),'all');
        I_total = sum(y(:,nI),'all');
        b = calc_beta(V_total, I_total, param);
        
        % calculate variant betas and append original strain beta, gamma,& mu (dbeta=1)
        b = [1 dbeta]*b;
        
        % calculate alpha(t)
        date = index2date(fixed_params.US_data,fixed_params.start_day,t(tidx));
        [alpha1,alpha2,alphaB] = calc_alpha(fixed_params,date,y);
        
        % VE(immunity #, variant #)
        % immunity #: unvaccinated, first dose, second dose, waning1, waning2
        VE = [zeros(1,1+n_var) ; [VE1 VE1V'] ; [VE2 VE2V'] ; [VES1 VES1V'] ; [VES2 VES2V']];
        
        % set vacc. outflow of compartment to zero if below threshold and reproportion
        weights = distribute_flows(y,vacc_threshold,nD);
        
        % waning immunity population proportions (for second dose and booster)
        propS1 = sum(y(nVS1,:))/(sum(y(nVS1,:)) + sum(y(nV1,:)));
        propS2 = sum(y(nVS2,:))/(sum(y(nVS2,:)) + sum(y(nV2,:)));
        propV1 = 1 - propS1;
        propV2 = 1 - propS2;
        
        % set propS1,propV1 with 1,0 (in case of 0/0=NaN)
        if isnan(propS1)
            propS1 = 1; propV1 = 0;
        end
        
        if isnan(propS2)
            propS2 = 1; propV2 = 0;
        end
        
        % define flows between stacks in stacked compartment model
        no_flow = zeros(1,size(y,2));
        
        % inflow from vaccination
        dydt_in = [no_flow ; ...
            alpha1 * weights(nUV,:) ; ...
            alpha2 * (propV1*weights(nV1,:)+propS1*weights(nVS1,:)) + alphaB * propS2*weights(nVS2,:) ; ...
            no_flow ; ...
            no_flow];
        
        % outflow from vaccination
        dydt_out = [alpha1 * weights(nUV,:) ; ...
            alpha2 * propV1*weights(nV1,:) ; ...
            no_flow ; ...
            alpha2 * propS1*weights(nVS1,:) ; ...
            alphaB * propS2*weights(nVS2,:)];
        
        % inflow from waning
        dydt_in = dydt_in + [no_flow ; ...
            no_flow ; ... % waning immunity from first dose
            no_flow ; ... % waning immunity from second dose
            y(nV1,:)/t_imm ; ... % waning immunity from first dose
            y(nV2,:)/t_imm]; % waning immunity from second dose

        % outflow from waning
        dydt_out = dydt_out + [no_flow ; ...
            y(nV1,:)/t_imm ; ... % waning immunity from first dose
            y(nV2,:)/t_imm ; ... % waning immunity from second dose
            no_flow ; ... % waning immunity from first dose
            no_flow]; % waning immunity from second dose
        
%         dydt_in =  zeros(size(y)); dydt_out = zeros(size(y));
        for nimm = [nUV nV1 nV2 nVS1 nVS2] %(1:5)
            S = y(nimm,nS); I = y(nimm,nI); R = y(nimm,nR); RW = y(nimm,nRW); D = y(nimm,nD);
            ve = VE(nimm,:);
        
            % differential equations (inflow)
            dydt_in(nimm,nI) = dydt_in(nimm,nI) + S.*b.*(1-ve).*I;
            dydt_in(nimm,nR) = dydt_in(nimm,nR) + gamma.*I;
            dydt_in(nimm,nRW) = dydt_in(nimm,nRW) + R/t_imm;
            dydt_in(nimm,nD) = dydt_in(nimm,nD) + sum(mu.*gamma.*I);

            % differential equations (outflow)
            dydt_out(nimm,nS) = dydt_out(nimm,nS) + S*sum((1-ve).*b.*I);
            dydt_out(nimm,nI) = dydt_out(nimm,nI) + (mu.*gamma + gamma).*I;
            dydt_out(nimm,nR) = dydt_out(nimm,nR) + R/t_imm;
        
            % add reinfections
            dydt_out(nimm,nR) = dydt_out(nimm,nR) + R.*(sum(k.*b.*I)-k.*b.*I);
            dydt_out(nimm,nRW) = dydt_out(nimm,nRW) + RW.*(sum(kw.*b.*I)-kw.*b.*I);

            % add reinfections
            dydt_in(nimm,nI) = dydt_in(nimm,nI) + k.*b.*(1-ve).*I.*(sum(R)-R) ...
                                                + kw.*b.*(1-ve).*I.*(sum(RW)-RW);
        end
        
        inflow(tidx,:,:) = dydt_in;
        outflow(tidx,:,:) = dydt_out;
    end
end