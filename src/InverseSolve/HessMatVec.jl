# This file contains implementations of HessMatVec for different types

export HessMatVec

# Hessian is diagonal matrix and stored as a vector.
function HessMatVec(d2F::Array{Float64,1}, x::Array{Float64,1})
	return d2F .* x
end

function HessMatVec(d2F::Array{Complex128,1}, x::Array{Complex128,1})
	return complex(real(d2F) .* real(x), imag(d2F) .* imag(x))
end

# Hessian is stored as a sparse matrix.
function HessMatVec(d2F::SparseMatrixCSC{Float64}, x::Array{Float64,1})
	return d2F * x
end

function HessMatVec(d2F::SparseMatrixCSC{Complex128}, x::Array{Complex128,1})
	return complex(real(d2F) * real(x), imag(d2F) * imag(x))
end

function HessMatVec(x,
                    pFor::ForwardProbType, 
                    sigma,  # conductivity on inv mesh (active cells only)
                    gloc::GlobalToLocal,
                    d2F)
	# 
	#	JTx = HessMatVec(x,pFor,mc,model,d2F)
	#	
	#	Hessian * Vector for one forward problem
	#	
	#	Note: all variables have to be in memory of the worker executing this method		
	#
	try
		sigmaloc = interpGlobalToLocal(sigma,gloc.PForInv,gloc.sigmaBackground)
		xloc     = interpGlobalToLocal(x,gloc.PForInv)
		Jx       = vec(getSensMatVec(xloc,sigmaloc,pFor))   # Jx = J*(dsig/dm)*x
		Jx       = HessMatVec(d2F,Jx) # chain rule for misfit function
		JTxloc   = getSensTMatVec(Jx,sigmaloc,pFor)
		JTx      = interpLocalToGlobal(JTxloc,gloc.PForInv) # = (dsig/dm)'*J'*d2F*J*(dsig/dm)*x
		return JTx
	catch err
		if isa(err,InterruptException) 
			return -1
		else
			throw(err)
		end
	end	
end # function HessMatVec


function HessMatVec(xRef::RemoteRef{Channel{Any}},
                    pForRef::RemoteRef{Channel{Any}},
                    sigmaRef::RemoteRef{Channel{Any}},
                    glocRef::RemoteRef{Channel{Any}},
                    d2FRef::RemoteRef{Channel{Any}},
					mvRef::RemoteRef{Channel{Any}})
	# 
	#	JTx = HessMatVec(x,pFor,mc,model,d2F)
	#	
	#	Hessian * Vector for one forward problem
	#	
	#	Note: model and forward problem are represented as RemoteReferences.
	#	 	  
	#	!! make sure that everything is stored on this worker to avoid communication !!
	#
	
	rrlocs = [xRef.where pForRef.where sigmaRef.where glocRef.where d2FRef.where mvRef.where]
	if !all(rrlocs .== myid())
		warn("HessMatVec: Problem on worker $(myid()) not all remote refs are stored here, but rrlocs=$rrlocs")
	end
	
	# fetching and taking: should be no-ops as all RemoteRefs live on my worker
	tic()
	x     = fetch(xRef)
	sigma = fetch(sigmaRef)
	pFor  = take!(pForRef)
	gloc  = fetch(glocRef)
	d2F   = fetch(d2FRef)
	commTime = toq()
	
	# compute HessMatVec
	tic()
	mvi  = HessMatVec(x,pFor,sigma,gloc,d2F)
	compTime = toq()
	
	# putting: should be no ops.
	tic()
	mv   = take!(mvRef)
	put!(mvRef,mv+mvi)
	put!(pForRef,pFor)
	commTime +=toq()
	
#	if commTime/compTime > 1.0
#		warn("HessMatVec:  Communication time larger than computation time! commTime/compTime = $(commTime/compTime)")
#	end
	return true,commTime,compTime
end

function HessMatVec(x,pForRef::RemoteRef{Channel{Any}},M2MRef::RemoteRef{Channel{Any}},sigma,gloc::GlobalToLocal,d2F)
	# 
	#	JTx = HessMatVec(x,pFor,mc,model,d2F)
	#	
	#	Hessian * Vector for one forward problem
	#	
	#	Note: forward problem and interpolation matrix are represented as RemoteReferences.
	#		  model does not have an interpolation matrix! (has to be plugged in)
	#	 	  
	#	!! make sure that everything is stored on this worker to avoid communication !!
	#
	rrlocs = [pForRef.where M2MRef.where]
	if !all(rrlocs .== myid())
		warn("HessMatVec: Problem on worker $(myid()) not all remote refs are stored here, but rrlocs=$rrlocs")
	end

	Pfor = fetch(pForRef)
	gloc.PForInv = fetch(M2MRef)
	mvi  = HessMatVec(x,Pfor,sigma,gloc,d2F)
	return mvi
end


function HessMatVec(x,
					pFor::Array{RemoteRef{Channel{Any}},1},
					sigma,
					gloc::Array{RemoteRef{Channel{Any}},1},
					d2F,
					indFors=1:length(pFor))
  # 
	#	JTx = HessMatVec(x,pFor,mc,model,d2F)
	#	
	#	Hessian * Vector for multiple forward problem
	#	
	#	Note: models and forward problems are represented as RemoteReferences.
	#
	
	tic()

	# find out which workers are involved
	workerList = []
	for k=1:length(pFor)
		push!(workerList,pFor[k].where)
	end
	workerList = unique(workerList)
	# send sigma to all workers
	sigmaRef = Array(RemoteRef{Channel{Any}},maximum(workers()))
	yRef = Array(RemoteRef{Channel{Any}},maximum(workers()))
	zRef = Array(RemoteRef{Channel{Any}},maximum(workers()))
	z = zeros(length(x))
	commTime = 0.0
	compTime = 0.0
	updateTimes(c1,c2) = (commTime+=c1; compTime+=c2)
	updateMV(x) = (z+=x) 
	
	tic()
	c2 = toq()
	updateTimes(0.0,c2)
	
	tic()
	@sync begin
		for p = workerList
			@async begin
				# send model and vector to worker
				tic()
				sigmaRef[p] = remotecall(p,identity,sigma)
				yRef[p]     = remotecall(p,identity,x)
				zRef[p]     = remotecall(p,identity,0.0)
				c1 = toq()
				updateTimes(c1,0.0)
				
				# do the actual computation
				for idx=indFors
					if pFor[idx].where==p
						b,c1,c2 = remotecall_fetch(p, HessMatVec,yRef[p],pFor[idx],sigmaRef[p],gloc[idx],d2F[idx],zRef[p])
						updateTimes(c1,c2)
					end
				end
				
				# get back result (timing is a mixture of addition and computation)
				tic()
				updateMV(fetch(zRef[p]))
				c1 = toq()
				updateTimes(c1,0.0)
			end
		end 
	end
	chkTime =toq()
	
	tic()
	matvc = z
	c2 = toq()
	updateTimes(0.0,c2)
	
	totalTime = toq()
#	@printf "Timings for HessMatVec - total: %1.3f, communication: %1.3f, computation: %1.3f\n" totalTime commTime compTime
	return matvc
end  # function HessMatVec


function HessMatVec(x,PF::Array,sigma,gloc::Array,d2F,indFors=1:length(PF))
	# 
	#	JTx = HessMatVec(x,pFor,mc,model,d2F)
	#	
	#	Hessian * Vector for multiple forward problem
	#	
	#	Note: models, interpolations and forward problems are stored on main process and then sent to workers
	#	
	#	!! this method may lead to more communication than the ones above !!
	#
	numFor = length(PF);
	
	# get process map
	i      = 1; nextidx(p) = i
	procMap = zeros(Int64,numFor)
	if isa(PF[1].Ainv,MUMPSsolver) && (PF[1].Ainv.Ainv.ptr !=-1)
		for ii=1:numFor
			if any(ii.==indFors)
				procMap[ii] = PF[ii].Ainv.Ainv.worker
			end
		end
		function nextidx(p)
			ind = find(procMap.==p)
			if !isempty(ind)
				ind = ind[1]
				procMap[ind] = -1
			end
			return ind
		end
	else
		nextidx(p) = (idx=i; i+=1; idx)
	end
	
	matvc = zeros(length(x))
	updateRes(x) = (matvc+=x)
	
	@sync begin
		for p = workers()
			@async begin
				while true
					idx = nextidx(p)
					if isempty(idx) || idx > numFor
						break
					end
					if any(idx.==indFors)
						zi = remotecall_fetch(p, HessMatVec,x,PF[idx],sigma,gloc[idx],d2F[idx])
						updateRes(zi)
					end
				end
			end
		end 
	end
	return matvc
end