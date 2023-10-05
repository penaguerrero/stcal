"""
Define the data which is fixed for all pixels to compute the CAS22 algorithm with
    jump detection

Objects
-------
FixedValues : class
    Class to contain the data fixed for all pixels and commonly referenced
    universal values for jump detection

Functions
---------
fixed_values_from_metadata : function
    Fast constructor for FixedValues from the read pattern metadata
"""
import numpy as np
cimport numpy as np
cimport cython

from stcal.ramp_fitting.ols_cas22._core cimport Thresh, ReadPatternMetadata, Diff
from stcal.ramp_fitting.ols_cas22._fixed cimport FixedValues

cdef class FixedValues:
    """
    Class to contain all the values which are fixed for all pixels for a given
    read pattern.
        This class is used to pre-compute these values once so that they maybe
        reused for all pixels.  This is done for performance reasons.

    Parameters
    ----------
    use_jump : bool
        flag to indicate whether to use jump detection (user input)

    data : ReadPatternMetadata
        Metadata struct created from a read pattern

    threshold : Thresh
        Parameterization struct for threshold function

    t_bar_diffs : float[:, :]
        These are the differences of t_bar used for jump detection.
            single differences of t_bar:
                t_bar_diffs[Diff.single, :] = (t_bar[i+1] - t_bar[i])
            double differences of t_bar:
                t_bar_diffs[Diff.double, :] = (t_bar[i+2] - t_bar[i])
    read_recip_coeffs : float[:, :]
        Coefficients for the read noise portion of the variance used to compute
        the jump detection statistics. These are formed from the reciprocal sum
        of the number of reads.
            single sum of reciprocal n_reads:
                recip[Diff.single, :] = ((1/n_reads[i+1]) + (1/n_reads[i]))
            double sum of reciprocal n_reads:
                recip[Diff.double, :] = ((1/n_reads[i+2]) + (1/n_reads[i]))
    var_slope_coeffs : float[:, :]
        Coefficients for the slope portion of the variance used to compute the
        jump detection statistics, which happend to be fixed for any given ramp
        fit.
            single of slope variance term:
                slope_var[Diff.single, :] = ([tau[i] + tau[i+1] - min(t_bar[i], t_bar[i+1]))
            double of slope variance term:
                slope_var[Diff.double, :] = ([tau[i] + tau[i+2] - min(t_bar[i], t_bar[i+2]))

    Notes
    -----
    - t_bar_diffs, read_recip_coeffs, var_slope_coeffs are only computed if
      use_jump is True.  These values represent reused computations for jump
      detection which are used by every pixel for jump detection. They are
      computed once and stored in the FixedValues for reuse by all pixels.
    - The computations are done using vectorized operations for some performance
      increases. However, this is marginal compaired with the performance increase
      from pre-computing the values and reusing them.
    """

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline float[:, :] t_bar_diff_vals(FixedValues self):
        """
        Compute the difference offset of t_bar

        Returns
        -------
        [
            <t_bar[i+1] - t_bar[i]>,
            <t_bar[i+2] - t_bar[i]>,
        ]
        """
        # Cast vector to memory view
        #    This way of doing it is potentially memory unsafe because the memory
        #    can outlive the vector. However, this is much faster (no copies) and
        #    much simpler than creating an intermediate wrapper which can pretend
        #    to be a memory view. In this case, I make sure that the memory view
        #    stays local to the function (numpy operations create brand new objects)
        cdef float[:] t_bar = <float [:self.data.t_bar.size()]> self.data.t_bar.data()
        cdef int end = len(t_bar)

        cdef np.ndarray[float, ndim=2] t_bar_diff_vals = np.zeros((2, self.data.t_bar.size() - 1), dtype=np.float32)

        t_bar_diff_vals[Diff.single, :] = np.subtract(t_bar[1:], t_bar[:end - 1]) 
        t_bar_diff_vals[Diff.double, :end - 2] = np.subtract(t_bar[2:], t_bar[:end - 2])
        t_bar_diff_vals[Diff.double, end - 2] = np.nan  # last double difference is undefined

        return t_bar_diff_vals

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline float[:, :] read_recip_vals(FixedValues self):
        """
        Compute the reciprical sum of the number of reads

        Returns
        -------
        [
            <(1/n_reads[i+1] + 1/n_reads[i])>,
            <(1/n_reads[i+2] + 1/n_reads[i])>,
        ]

        """
        # Cast vector to memory view
        #    This way of doing it is potentially memory unsafe because the memory
        #    can outlive the vector. However, this is much faster (no copies) and
        #    much simpler than creating an intermediate wrapper which can pretend
        #    to be a memory view. In this case, I make sure that the memory view
        #    stays local to the function (numpy operations create brand new objects)
        cdef int[:] n_reads = <int [:self.data.n_reads.size()]> self.data.n_reads.data()
        cdef int end = len(n_reads)

        cdef np.ndarray[float, ndim=2] read_recip_vals = np.zeros((2, self.data.n_reads.size() - 1), dtype=np.float32)

        read_recip_vals[Diff.single, :] = (np.divide(1.0, n_reads[1:], dtype=np.float32) +
                                           np.divide(1.0, n_reads[:end - 1], dtype=np.float32))
        read_recip_vals[Diff.double, :end - 2] = (np.divide(1.0, n_reads[2:], dtype=np.float32) +
                                                  np.divide(1.0, n_reads[:end - 2], dtype=np.float32))
        read_recip_vals[Diff.double, end - 2] = np.nan  # last double difference is undefined

        return read_recip_vals


    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline float[:, :] var_slope_vals(FixedValues self):
        """
        Compute slope part of the jump statistic variances

        Returns
        -------
        [
            <(tau[i] + tau[i+1] - min(t_bar[i], t_bar[i+1])) * correction(i, i+1)>,
            <(tau[i] + tau[i+2] - min(t_bar[i], t_bar[i+2])) * correction(i, i+2)>,
        ]
        """
        # Cast vectors to memory views
        #    This way of doing it is potentially memory unsafe because the memory
        #    can outlive the vector. However, this is much faster (no copies) and
        #    much simpler than creating an intermediate wrapper which can pretend
        #    to be a memory view. In this case, I make sure that the memory view
        #    stays local to the function (numpy operations create brand new objects)
        cdef float[:] t_bar = <float [:self.data.t_bar.size()]> self.data.t_bar.data()
        cdef float[:] tau = <float [:self.data.tau.size()]> self.data.tau.data()
        cdef int end = len(t_bar)

        cdef np.ndarray[float, ndim=2] var_slope_vals = np.zeros((2, self.data.t_bar.size() - 1), dtype=np.float32)

        var_slope_vals[Diff.single, :] = (np.add(tau[1:], tau[:end - 1]) - np.minimum(t_bar[1:], t_bar[:end - 1]))
        var_slope_vals[Diff.double, :end - 2] = (np.add(tau[2:], tau[:end - 2]) - np.minimum(t_bar[2:], t_bar[:end - 2]))
        var_slope_vals[Diff.double, end - 2] = np.nan  # last double difference is undefined

        return var_slope_vals


cdef inline FixedValues fixed_values_from_metadata(ReadPatternMetadata data, Thresh threshold, bool use_jump):
    """
    Fast constructor for FixedValues class
        Use this instead of an __init__ because it does not incure the overhead
        of switching back and forth to python

    Parameters
    ----------
    data : ReadPatternMetadata
        metadata object created from the read pattern (user input)
    threshold : Thresh
        threshold object (user input)
    use_jump : bool
        flag to indicate whether to use jump detection (user input)

    Returns
    -------
    FixedValues object (with pre-computed values for jump detection if use_jump
    is True)
    """
    cdef FixedValues fixed = FixedValues()

    # Fill in input information for all pixels
    fixed.use_jump = use_jump
    fixed.threshold = threshold

    # Cast vector to a c array
    fixed.data = data

    # Pre-compute jump detection computations shared by all pixels
    if use_jump:
        fixed.t_bar_diffs = fixed.t_bar_diff_vals()
        fixed.read_recip_coeffs = fixed.read_recip_vals()
        fixed.var_slope_coeffs = fixed.var_slope_vals()

    return fixed
