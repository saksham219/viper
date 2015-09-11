#' VIPER
#'
#' This function performs Virtual Inference of Protein-activity by Enriched Regulon analysis
#'
#' @param eset ExpressionSet object or Numeric matrix containing the expression data or gene expression signatures, with samples in columns and genes in rows
#' @param regulon Object of class regulon
#' @param dnull Numeric matrix for the null model, usually generated by \code{nullTtest}
#' @param pleiotropy Logical, whether correction for pleiotropic regulation should be performed
#' @param nes Logical, whether the enrichment score reported should be normalized
#' @param method Character string indicating the method for computing the single samples signature, either scale, rank, mad, ttest or none
#' @param bootstraps Integer indicating the number of bootstraps iterations to perform. Only the scale method is implemented with bootstraps.
#' @param minsize Integer indicating the minimum number of targets allowed per regulon
#' @param adaptive.size Logical, whether the weighting scores should be taken into account for computing the regulon size
#' @param eset.filter Logical, whether the dataset should be limited only to the genes represented in the interactome
#' @param pleiotropyArgs list of 5 numbers for the pleotropy correction indicating: regulators p-value threshold, pleiotropic interaction p-value threshold, minimum number of targets in the overlap between pleiotropic regulators, penalty for the pleiotropic interactions and the method for computing the pleiotropy, either absolute or adaptive
#' @param cores Integer indicating the number of cores to use (only 1 in Windows-based systems)
#' @param verbose Logical, whether progression messages should be printed in the terminal
#' @return A matrix of inferred activity for each regulator gene in the network across all samples
#' @seealso \code{\link{msviper}}
#' @examples
#' data(bcellViper, package="bcellViper")
#' d1 <- exprs(dset)
#' res <- viper(d1, regulon)
#' dim(d1)
#' d1[1:5, 1:5]
#' regulon
#' dim(res)
#' res[1:5, 1:5]
#' @export

viper <- function(eset, regulon, dnull=NULL, pleiotropy=FALSE, nes=TRUE, method=c("scale", "rank", "mad", "ttest", "none"), bootstraps=0, minsize=25, adaptive.size=FALSE, eset.filter=TRUE, pleiotropyArgs=list(regulators=.05, shadow=.05, targets=10, penalty=20, method="adaptive"), cores=1, verbose=TRUE) {
    method <- match.arg(method)
    pdata <- NULL
    if (is(eset, "viperSignature")) {
        dnull <- eset$nullmodel
        eset <- eset$signature
        method="none"
        if (bootstraps>0) {
            bootstraps <- 0
            warning("Using a null model, bootstraps iterations are ignored.", call.=FALSE)
        }
    }
    if (pleiotropy & bootstraps>0) {
        bootstraps <- 0
        warning("Using pleiotropic correction, bootstraps iterations are ignored.", call.=FALSE)
    }
    if (is(eset, "ExpressionSet")) {
        pdata <- phenoData(eset)
        eset <- exprs(eset)
    } else if (is.data.frame(eset)) {
        eset <- as.matrix(eset)
    }
    if (is.null(nrow(eset))) eset <- matrix(eset, length(eset), 1, dimnames=list(names(eset), NULL))
    if (eset.filter) {
        tmp <- c(names(regulon), unlist(lapply(regulon, function(x) names(x$tfmode)), use.names=FALSE))
        eset <- eset[rownames(eset) %in% unique(tmp), ]
    }
    if (verbose) message("\nComputing the association scores")
    regulon <- lapply(regulon, function(x, genes) {
        filtro <- names(x$tfmode) %in% genes
        x$tfmode <- x$tfmode[filtro]
        if (length(x$likelihood)==length(filtro)) x$likelihood <- x$likelihood[filtro]
        return(x)
    }, genes=rownames(eset))
    if (adaptive.size) regulon <- regulon[sapply(regulon, function(x) {
        sum(x$likelihood/max(x$likelihood))
    })>=minsize]
    else regulon <- regulon[sapply(regulon, function(x) length(x$tfmode))>=minsize]
    if (bootstraps>0) {
        return(bootstrapViper(eset=eset, regulon=regulon, nes=nes, bootstraps=bootstraps, cores=cores, verbose=verbose))
    }
    switch(method,
		scale={tt <- t(scale(t(eset)))},
		rank={tt <- t(apply(eset, 1, rank))*punif(length(eset), -.1, .1)},
		mad={tt <- t(apply(eset, 1, function(x) (x-median(x))/mad(x)))},
		ttest={
            tt <- sapply(1:ncol(eset), function(i, eset) rowTtest(eset[, i]-eset[, -i])$statistic, eset=eset)
            colnames(tt) <- colnames(eset)
            rownames(tt) <- rownames(eset)
        },
		none={tt <- eset}
	)
    if (verbose) message("Computing regulons enrichment with aREA")
    es <- aREA(tt, regulon, cores=cores, verbose=verbose)
    if (!nes) {
        if (pleiotropy) warning("No pleiotropy correction implemented when raw es is returned.", call.=FALSE)
        return(es$es)
    }
    if (is.null(dnull)) nes <- es$nes
    else {
        if (verbose) message("\nEstimating NES with null model")
        tmp <- aREA(dnull, regulon, cores=cores, verbose=verbose)$es
        nes <- t(sapply(1:nrow(tmp), function(i, tmp, es) {
            aecdf1(tmp[i, ], symmetric=TRUE, es[i, ])$nes
        }, tmp=tmp, es=es$es))
        rownames(nes) <- rownames(es$nes)
    }
    if (pleiotropy) {
        pb <- NULL
        if (verbose) {
            message("\nComputing pleiotropy for ", ncol(nes), " samples.")
            message("\nProcess started at ", date())
        }
        if (cores>1) {
            nes <- mclapply(1:ncol(nes), function(i, ss, nes, regulon, args, dnull) {
                nes <- nes[, i]
                sreg <- shadowRegulon(ss[, i], nes, regulon, regulators=args[[1]], shadow=args[[2]], targets=args[[3]], penalty=args[[4]], method=args[[5]])
                if (!is.null(sreg)) {
                    if (is.null(dnull)) tmp <-aREA(ss[, i], sreg, cores=1)$nes[, 1]
                    else {
                        tmp <- aREA(cbind(ss[, i], dnull), sreg, cores=1)$es
                        tmp <- apply(tmp, 1, function(x) aecdf1(x[-1], symmetric=TRUE, x[1])$nes)
                    }
                    nes[match(names(tmp), names(nes))] <- tmp
                }
                return(nes)
            }, ss=tt, nes=nes, regulon=regulon, args=pleiotropyArgs, dnull=dnull, mc.cores=cores)
            nes <- sapply(nes, function(x) x)    
        }
        else {
            if (verbose) pb <- txtProgressBar(max=ncol(nes), style=3)
            nes <- sapply(1:ncol(nes), function(i, ss, nes, regulon, args, dnull, pb) {
                nes <- nes[, i]
                sreg <- shadowRegulon(ss[, i], nes, regulon, regulators=args[[1]], shadow=args[[2]], targets=args[[3]], penalty=args[[4]], method=args[[5]])
                if (!is.null(sreg)) {
                    if (is.null(dnull)) tmp <-aREA(ss[, i], sreg)$nes[, 1]
                    else {
                        tmp <- aREA(cbind(ss[, i], dnull), sreg)$es
                        tmp <- apply(tmp, 1, function(x) aecdf1(x[-1], symmetric=TRUE, x[1])$nes)
                    }
                    nes[match(names(tmp), names(nes))] <- tmp
                }
                if (is(pb, "txtProgressBar")) setTxtProgressBar(pb, i)    
                return(nes)
            }, ss=tt, nes=nes, regulon=regulon, args=pleiotropyArgs, dnull=dnull, pb=pb)
        }
        if (verbose) message("\nProcess ended at ", date(), "\n")
        if (is.null(nrow(nes))) nes <- matrix(nes, length(nes), 1, dimnames=list(names(nes), NULL))
        colnames(nes) <- colnames(eset)
    }
    if (is.null(pdata)) return(nes)
    return(ExpressionSet(assayData=nes, phenoData=pdata))
}

##########
#' Generic S4 method for signature and sample-permutation null model for VIPER
#' 
#' This function generates a viperSignature object from a test dataset based on a set of samples to use as reference
#' 
#' @param eset ExpressionSet object or numeric matrix containing the test dataset, with genes in rows and samples in columns
#' @param ... Additional parameters added to keep compatibility
#' @return viperSignature S3 object containing the signature and null model
#' @export
#' @docType methods
#' @rdname viperSignature-methods
setGeneric("viperSignature", function(eset, ...) standardGeneric("viperSignature"))

#' @param pheno Character string indicating the phenotype data to use
#' @param refgroup Vector of character string indicatig the category of \code{pheno} to use as reference group
#' @param method Character string indicating how to compute the signature and null model, either ttest, zscore or mean
#' @param per Integer indicating the number of sample permutations
#' @param seed Integer indicating the seed for the random sample generation. The system default is used when set to zero
#' @param cores Integer indicating the number of cores to use (only 1 in Windows-based systems)
#' @param verbose Logical, whether progression messages should be printed in the terminal
#' @examples
#' data(bcellViper, package="bcellViper")
#' ss <- viperSignature(dset, "description", c("N", "CB", "CC"))
#' res <- viper(ss, regulon)
#' dim(exprs(dset))
#' exprs(dset)[1:5, 1:5]
#' regulon
#' dim(res)
#' res[1:5, 1:5]
#' @rdname viperSignature-methods
#' @aliases viperSignature,ExpressionSet-method
setMethod("viperSignature", "ExpressionSet", function(eset, pheno, refgroup, method=c("ttest", "zscore", "mean"), per=1000, seed=1, cores=1, verbose=TRUE) {
    method <- match.arg(method)
    pos <- pData(eset)[[pheno]] %in% refgroup
    tmp <- viperSignature(exprs(eset)[, !pos], exprs(eset)[, pos], method=method, per=per, seed=seed, cores=cores, verbose=verbose)
    pdata <- phenoData(eset)
    pData(pdata) <- pData(pdata)[match(colnames(tmp$signature), rownames(pData(pdata))), ]
    tmp$signature <- ExpressionSet(assayData=tmp$signature, phenoData=pdata)
    return(tmp)
})

#' @param ref Numeric matrix containing the reference samples (columns) and genes in rows
#' @examples
#' data(bcellViper, package="bcellViper")
#' d1 <- exprs(dset)
#' ss <- viperSignature(d1[, -(1:5)], d1[, 1:5])
#' res <- viper(ss, regulon)
#' dim(d1)
#' d1[1:5, 1:5]
#' regulon
#' dim(res)
#' res[1:5, 1:5]
#' @rdname viperSignature-methods
#' @aliases viperSignature,matrix-method
setMethod("viperSignature", "matrix", function(eset, ref, method=c("ttest", "zscore", "mean"), per=1000, seed=1, cores=1, verbose=TRUE) {
    method <- match.arg(method)
    if (seed>0) set.seed(ceiling(seed))
    switch(method,
    ttest={
        vpsig <- apply(eset, 2, function(x, ctrl) {
            tmp <- rowTtest(x-ctrl)
            (qnorm(tmp$p.value/2, lower.tail=FALSE)*sign(tmp$statistic))[, 1]
        }, ctrl=ref)
        rownames(vpsig) <- rownames(eset)
        colnames(vpsig) <- colnames(eset)
    },
    zscore={
        vpsig <- (eset-rowMeans(ref))/sqrt(frvarna(ref)[, 1])
    },
    mean={
        vpsig <- eset-rowMeans(ref)
    })
    if ((ncol(eset)+ncol(ref))<12) {
        vpnull <- NULL
        warning("Not enough samples to compute null model by sample permutation, gene permutation will be used instead", call.=FALSE)
    }
    else {
        if (ncol(ref)<12) {
            warning("Not enough reference samples to compute null model, all samples will be used", call.=FALSE)
            ref <- cbind(ref, eset)
        }
        nco <- choose(ncol(ref), round(ncol(ref)/2))
        if (nco<(50*per)) {
            per1 <- combn(sample(ncol(ref)), round(ncol(ref)/2))[, 1:min(per, nco)]
        }
        else {
            per1 <- sapply(1:(min(per, nco)), function(i, n1, n2) sample(n1, n2), n1=ncol(ref), n2=round(ncol(ref)/2))
        }
        pb <- NULL
        if (cores>1) {
            vpnull <- mclapply(1:ncol(per1), function(i, dset, ref, size, method, per1) {
                switch(method,
                       ttest={
                           tmp <- NA
                           while(any(is.na(tmp))) {
                               pos <- sample(ncol(dset), size)
                               tmp <- rowTtest(dset[, pos[1]]-dset[, pos[-1]])
                               tmp <- (qnorm(tmp$p.value/2, lower.tail=FALSE)*sign(tmp$statistic))[, 1]
                           }
                       },
                       zscore={
                           pos <- per1[, i]
                           tmp <- (rowMeans(ref[, pos])-rowMeans(ref[, -pos]))/(sqrt(frvarna(ref[, pos])[, 1])+sqrt(frvarna(ref[, -pos])[, 1]))
                       },
                       mean={
                           pos <- per1[, i]
                           tmp <- rowMeans(ref[, pos])-rowMeans(ref[, -pos])
                       })
                return(tmp)
            }, dset=cbind(eset, ref), ref=ref, size=ncol(ref)+1, method=method, per1=per1, mc.cores=cores)
            vpnull <- sapply(vpnull, function(x) x)    
        }
        else {
            if (verbose) pb <- txtProgressBar(max=ncol(per1), style=3)
            vpnull <- sapply(1:ncol(per1), function(i, dset, ref, pb, size, verbose, method, per1) {
                if (verbose) setTxtProgressBar(pb, i)
                switch(method,
                ttest={
                    tmp <- NA
                    while(any(is.na(tmp))) {
                        pos <- sample(ncol(dset), size)
                        tmp <- rowTtest(dset[, pos[1]]-dset[, pos[-1]])
                        tmp <- (qnorm(tmp$p.value/2, lower.tail=FALSE)*sign(tmp$statistic))[, 1]
                    }
                },
                zscore={
                    pos <- per1[, i]
                    tmp <- (rowMeans(ref[, pos])-rowMeans(ref[, -pos]))/(sqrt(frvarna(ref[, pos])[, 1])+sqrt(frvarna(ref[, -pos])[, 1]))
                },
                mean={
                    pos <- per1[, i]
                    tmp <- rowMeans(ref[, pos])-rowMeans(ref[, -pos])
                })
                return(tmp)
            }, dset=cbind(eset, ref), ref=ref, size=ncol(ref)+1, pb=pb, verbose=verbose, method=method, per1=per1)
        }
        rownames(vpnull) <- rownames(eset)
    }
    tmp <- list(signature=vpsig, nullmodel=vpnull)
    class(tmp) <- "viperSignature"
    return(tmp)
})

#' bootstrapsViper
#' 
#' This function performs a viper analysis with bootstraps
#' 
#' @param eset ExpressionSet object or Numeric matrix containing the expression data, with samples in columns and genes in rows
#' @param regulon Object of class regulon
#' @param nes Logical, whether the enrichment score reported should be normalized
#' @param bootstraps Integer indicating the number of bootstraps iterations to perform. Only the scale method is implemented with bootstraps.
#' @param cores Integer indicating the number of cores to use (only 1 in Windows-based systems)
#' @param verbose Logical, whether progression messages should be printed in the terminal
#' @return A list containing a matrix of inferred activity for each regulator gene in the network across all samples and the corresponding standard deviation computed from the bootstrap iterations.
#' @seealso \code{\link{viper}}
#' @examples
#' data(bcellViper, package="bcellViper")
#' d1 <- exprs(dset)
#' res <- viper(d1, regulon, bootstraps=10)
#' dim(d1)
#' d1[1:5, 1:5]
#' regulon
#' dim(res$nes)
#' res$nes[1:5, 1:5]
#' res$sd[1:5, 1:5]
bootstrapViper <- function(eset, regulon, nes=TRUE, bootstraps=10, cores=1, verbose=TRUE) {
    targets <- unique(unlist(lapply(regulon, function(x) names(x$tfmode)), use.names=FALSE))
    mor <- sapply(regulon, function(x, genes) {
        return(x$tfmode[match(genes, names(x$tfmode))])
    }, genes=targets)
    wts <- sapply(regulon, function(x, genes) {
        tmp <- x$likelihood[match(genes, names(x$tfmode))]
        tmp[is.na(match(genes, names(x$tfmode)))] <- NA
        return(tmp/max(tmp, na.rm=T))
    }, genes=targets)
    mor[is.na(mor)] <- 0
    wts[is.na(wts)] <- 0
    rownames(wts) <- targets
    nes <- sqrt(colSums(wts^2))
    wts <- scale(wts, center=FALSE, scale=colSums(wts))
    eset <- eset[match(rownames(wts), rownames(eset)), ]
    tmp <- lapply(1:bootstraps, function(i, eset) {
        tmp <- eset[, sample(ncol(eset), replace=TRUE)]
        return(list(mean=rowMeans(tmp), sd=sqrt(frvarna(tmp)[, 1])))
    }, eset=eset)
    btmean <- sapply(tmp, function(x) x$mean)
    btsd <- sapply(tmp, function(x) x$sd)
    pb <- NULL
    if (verbose) {
        message("\nComputing the parameters for ", bootstraps, " bootstraps.")
        message("Process started at ", date())
    }
    if (cores>1) {
        res <- mclapply(1:ncol(eset), function(i, eset, btmean, btsd, mor, wts) {
            tt <- (eset[, i]-btmean)/btsd
            tt <- apply(tt, 2, function(x) rank(x))/(nrow(tt)+1)
            t1 <- abs(tt-.5)*2
            t1 <- t1+(1-max(t1))/2
            t1 <- qnorm(t1)
            t2 <- qnorm(tt)
            sum1 <- t(mor * wts) %*% t2
            sum2 <- t((1-abs(mor)) * wts) %*% t1
            ss <- sign(sum1)
            ss[ss==0] <- 1
            tmp <- (abs(sum1) + sum2*(sum2>0))*ss
            return(list(mean=rowMeans(tmp), sd=sqrt(frvarna(tmp)[, 1])))
        }, eset=eset, btmean=btmean, btsd=btsd, mor=mor, wts=wts, mc.cores=cores)
    }
    else {
        if (verbose) pb <- txtProgressBar(max=ncol(eset), style=3)
        res <- lapply(1:ncol(eset), function(i, eset, btmean, btsd, mor, wts, pb) {
            tt <- (eset[, i]-btmean)/btsd
            tt <- apply(tt, 2, function(x) rank(x))/(nrow(tt)+1)
            t1 <- abs(tt-.5)*2
            t1 <- t1+(1-max(t1))/2
            t1 <- qnorm(t1)
            t2 <- qnorm(tt)
            sum1 <- t(mor * wts) %*% t2
            sum2 <- t((1-abs(mor)) * wts) %*% t1
            ss <- sign(sum1)
            ss[ss==0] <- 1
            tmp <- (abs(sum1) + sum2*(sum2>0))*ss
            if (is(pb, "txtProgressBar")) setTxtProgressBar(pb, i)    
            return(list(mean=rowMeans(tmp), sd=sqrt(frvarna(tmp)[, 1])))
        }, eset=eset, btmean=btmean, btsd=btsd, mor=mor, wts=wts, pb=pb)
    }
    names(res) <- colnames(eset)
    if (verbose) message("\nProcess ended at ", date())
    return(list(nes=sapply(res, function(x) x$mean)*nes, sd=sapply(res, function(x) x$sd)*nes))
}

#' analytic Rank-based Enrichment Analysis
#' 
#' This function performs wREA enrichment analysis on a set of signatues
#' 
#' @param eset Matrix containing a set of signatures, with samples in columns and traits in rows
#' @param regulon Regulon object
#' @param method Character string indicating the implementation, either auto, matrix or loop
#' @param minsize Interger indicating the minimum allowed size for the regulons
#' @param cores Integer indicating the number of cores to use (only 1 in Windows-based systems)
#' @param wm Optional numeric matrix of weights (0; 1) with same dimension as eset
#' @param verbose Logical, whether a progress bar should be shown
#' @return List of two elements, enrichment score and normalized enrichment score
#' @export

aREA <- function(eset, regulon, method=c("auto", "matrix", "loop"), minsize=20, cores=1, wm=NULL, verbose=FALSE) {
    method <- match.arg(method)
    if (is.null(ncol(eset))) eset <- matrix(eset, length(eset), 1, dimnames=list(names(eset), NULL))
    if (minsize>0) {
        regulon <- lapply(regulon, function(x, genes) {
            pos <- names(x$tfmode) %in% genes
            list(tfmode=x$tfmode[pos], likelihood=x$likelihood[pos])
        }, genes=rownames(eset))
        regulon <- regulon[sapply(regulon, function(x) length(x$tfmode))>=minsize]
        class(regulon) <- "regulon"
    }
    targets <- unique(unlist(lapply(regulon, function(x) names(x$tfmode)), use.names=FALSE))
    if (method=="auto") {
        method <- "matrix"
        if (length(targets)>1000) method <- "loop"
        if (!is.na(wm)) method <- "loop"
    }
    switch(method,
    matrix={
        mor <- sapply(regulon, function(x, genes) {
            return(x$tfmode[match(genes, names(x$tfmode))])
        }, genes=targets)
        wts <- sapply(regulon, function(x, genes) {
            tmp <- x$likelihood[match(genes, names(x$tfmode))]
            tmp[is.na(match(genes, names(x$tfmode)))] <- NA
            return(tmp/max(tmp, na.rm=T))
        }, genes=targets)
        mor[is.na(mor)] <- 0
        wts[is.na(wts)] <- 0
        nes <- sqrt(colSums(wts^2))
        wts <- scale(wts, center=FALSE, scale=colSums(wts))
        pos <- match(targets, rownames(eset))
        t2 <- apply(eset, 2, rank)/(nrow(eset)+1)
        t1 <- abs(t2-.5)*2
        t1 <- t1+(1-max(t1))/2
        t1 <- qnorm(filterRowMatrix(t1, pos))
        t2 <- qnorm(filterRowMatrix(t2, pos))
        sum1 <- t(mor * wts) %*% t2
        sum2 <- t((1-abs(mor)) * wts) %*% t1
        ss <- sign(sum1)
        ss[ss==0] <- 1
        tmp <- (abs(sum1) + sum2*(sum2>0))*ss
        tmp <- list(es=tmp, nes=tmp*nes)
    },
    loop={
        t2 <- apply(eset, 2, rank)/(nrow(eset)+1)
        t1 <- abs(t2-.5)*2
        t1 <- t1+(1-max(t1))/2
        t1 <- qnorm(t1)
        t2 <- qnorm(t2)
        if (is.null(wm)) wm <- matrix(1, nrow(eset), ncol(eset), dimnames=list(rownames(eset), colnames(eset)))
        pb <- NULL
        if (cores>1) {
            temp <- mclapply(1:length(regulon), function(i, regulon, t1, t2, ws) {
                x <- regulon[[i]]
                pos <- match(names(x$tfmode), rownames(t1))
                sum1 <- matrix(x$tfmode * x$likelihood, 1, length(x$tfmode)) %*% filterRowMatrix(t2, pos)
                ss <- sign(sum1)
                ss[ss==0] <- 1
                sum2 <- matrix((1-abs(x$tfmode)) * x$likelihood, 1, length(x$tfmode)) %*% filterRowMatrix(t1, pos)
                return(as.vector(abs(sum1) + sum2*(sum2>0)) / colSums(x$likelihood * filterRowMatrix(ws, pos)) * ss)
            }, regulon=regulon, t1=t1, t2=t2, mc.cores=cores, ws=wm)
            temp <- sapply(temp, function(x) x)    
        }
        else {
            if (verbose) {
                pb <- txtProgressBar(max=length(regulon), style=3)
            }
            temp <- sapply(1:length(regulon), function(i, regulon, t1, t2, pb, ws) {
                x <- regulon[[i]]
                pos <- match(names(x$tfmode), rownames(t1))
                sum1 <- matrix(x$tfmode * x$likelihood, 1, length(x$tfmode)) %*% filterRowMatrix(t2, pos)
                ss <- sign(sum1)
                ss[ss==0] <- 1
                sum2 <- matrix((1-abs(x$tfmode)) * x$likelihood, 1, length(x$tfmode)) %*% filterRowMatrix(t1, pos)
                if (is(pb, "txtProgressBar")) setTxtProgressBar(pb, i)
                return(as.vector(abs(sum1) + sum2*(sum2>0)) / colSums(x$likelihood * filterRowMatrix(ws, pos)) * ss)
            }, regulon=regulon, t1=t1, t2=t2, pb=pb, ws=wm)
        }
        if (is.null(ncol(temp))) temp <- matrix(temp, 1, length(temp))
        colnames(temp) <- names(regulon)
        rownames(temp) <- colnames(eset)
        if (length(which(wm<1))>0) {
            w <- sapply(regulon, function(x, ws) {
                tmp <- x$likelihood*filterRowMatrix(ws, match(names(x$tfmode), rownames(ws)))
              sqrt(colSums(apply(tmp, 2, function(x) x/max(x))^2))
            }, ws=wm)
            w <- t(w)
        }
        else {
            w <- sapply(regulon, function(x) sqrt(sum((x$likelihood/max(x$likelihood))^2)))
        }
        return(list(es=t(temp), nes=t(temp)*w))
    })
    return(tmp)
}
